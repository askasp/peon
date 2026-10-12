defmodule Beamcode.TicketsTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.Tickets

  @moduletag :tmp_dir

  @ticket """
  ---
  id: tkt-1
  status: open
  deps: []
  links: []
  created: 2026-01-02T03:04:05Z
  type: feature
  priority: 1
  assignee: me
  tags: [ui, api]
  ---
  # Ship it

  The body line.

  ## Notes

  **2026-01-03T00:00:00Z**

  First note
  """

  setup %{tmp_dir: dir} do
    commands = start_supervised!({Agent, fn -> [] end})
    output = start_supervised!({Agent, fn -> "tkt-9\n" end}, id: :output)

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/fs/list"} ->
          if URI.decode_query(conn.query_string)["path"] == ".tickets",
            do: data(conn, [%{"path" => ".tickets/tkt-1.md", "type" => "file"}]),
            else: data(conn, [])

        {"GET", "/api/fs/read/" <> _path} ->
          conn
          |> Plug.Conn.put_resp_content_type("text/markdown")
          |> Plug.Conn.send_resp(200, @ticket)

        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(commands, &(&1 ++ [Jason.decode!(body)["command"]]))
          data(conn, %{"id" => "sh1"})

        {"GET", "/api/shell/sh1"} ->
          data(conn, %{"status" => "exited", "exit" => 0})

        {"GET", "/api/shell/sh1/output"} ->
          data(conn, %{"output" => Agent.get(output, & &1)})
      end
    end)

    %{
      project: project_fixture(%{name: "tk", kind: "code", directory: dir}, nil),
      commands: commands,
      output: output
    }
  end

  test "reads a Folder's tasks from .tickets/", %{project: project} do
    assert {:ok, [t]} = Tickets.list(project)

    assert t["id"] == "tkt-1"
    assert t["title"] == "Ship it"
    assert t["status"] == "open"
    assert t["type"] == "feature"
    assert t["priority"] == 1
    assert t["tags"] == ["ui", "api"]
    assert t["body"] == "The body line."
    assert t["notes"] == [%{"at" => "2026-01-03T00:00:00Z", "text" => "First note"}]
  end

  test "queues a task, then moves it and notes progress", %{project: project, commands: commands} do
    assert {:ok, %{"id" => "tkt-9"}} =
             Tickets.create(project, %{
               "title" => "New task",
               "description" => "why",
               "priority" => 3
             })

    assert :ok = Tickets.set_status(project, "tkt-9", "in_progress")
    assert :ok = Tickets.note(project, "tkt-9", "a note")

    cmds = Agent.get(commands, & &1)
    assert Enum.any?(cmds, &(&1 =~ "tk create 'New task'" and &1 =~ "-d 'why'" and &1 =~ "-p 3"))
    assert "tk status 'tkt-9' in_progress" in cmds
    assert "tk add-note 'tkt-9' 'a note'" in cmds
  end

  test "rejects a bad status and empty notes", %{project: project} do
    assert {:error, _} = Tickets.set_status(project, "tkt-9", "sideways")
    assert {:error, _} = Tickets.note(project, "tkt-9", "   ")
    assert {:error, _} = Tickets.set_status(project, "../etc", "open")
  end

  test "reads every tree's tasks in one shell call", %{project: project, output: output} do
    other =
      String.replace(@ticket, "tkt-1", "tkt-2")
      |> String.replace("status: open", "status: closed")

    Agent.update(output, fn _ ->
      "\x1eD /main\n\x1eD /wt/brave\n\x1eF\n" <> other <> "\x1eF\n" <> @ticket
    end)

    assert %{"/main" => [], "/wt/brave" => [a, b]} =
             Tickets.list_trees(project, ["/main", "/wt/brave"])

    assert {a["id"], b["id"]} == {"tkt-1", "tkt-2"}
  end

  test "rewrites title, body, priority and the paused tag, keeping notes" do
    assert {:ok, next} =
             Tickets.rewrite(@ticket, %{
               "title" => "Ship it now",
               "body" => "New body.",
               "priority" => 0,
               "paused" => true
             })

    t = Tickets.parse(next)
    assert t["title"] == "Ship it now"
    assert t["body"] == "New body."
    assert t["priority"] == 0
    assert t["tags"] == ["ui", "api", "paused"]
    assert t["notes"] == [%{"at" => "2026-01-03T00:00:00Z", "text" => "First note"}]
    assert t["id"] == "tkt-1"

    assert {:ok, again} = Tickets.rewrite(next, %{"paused" => false})
    assert Tickets.parse(again)["tags"] == ["ui", "api"]

    assert {:error, _} = Tickets.rewrite(@ticket, %{"title" => " "})
    assert {:error, _} = Tickets.rewrite(@ticket, %{"priority" => 9})
  end
end
