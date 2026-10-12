defmodule Beamcode.TaskQueueTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.{Projects, TaskQueue, Tickets}

  @moduletag :tmp_dir
  # Runs the real `tk` in temporary folders.
  if !System.find_executable("tk"), do: @moduletag(:skip)

  # A Code Folder's main and one chat's worktree, with an OpenCode whose shell
  # and files are those folders and whose chat records what it's told.
  setup %{tmp_dir: dir} do
    main = Path.join(dir, "main")
    wt = Path.join(dir, "brave-lagoon")
    File.mkdir_p!(main)
    File.mkdir_p!(wt)
    runs = start_supervised!({Agent, fn -> %{} end})
    told = start_supervised!({Agent, fn -> [] end}, id: :told)

    session = %{
      "id" => "s1",
      "title" => "Fix checkout",
      "location" => %{"directory" => wt},
      "time" => %{"updated" => 1}
    }

    setup_stub(fn conn ->
      at = URI.decode_query(conn.query_string)["location[directory]"]

      case {conn.method, conn.request_path} do
        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          # zsh when there is one, like OpenCode's shell: it's stricter (a glob
          # that matches nothing is an error).
          {out, code} =
            System.cmd(
              System.find_executable("zsh") || "sh",
              ["-c", Jason.decode!(body)["command"]],
              cd: at,
              stderr_to_stdout: true
            )

          id = "sh#{System.unique_integer([:positive])}"
          Agent.update(runs, &Map.put(&1, id, {code, out}))
          data(conn, %{"id" => id})

        {"GET", "/api/shell/" <> rest} ->
          case String.split(rest, "/") do
            [id] ->
              data(conn, %{"status" => "done", "exit" => elem(Agent.get(runs, & &1[id]), 0)})

            [id, "output"] ->
              data(conn, %{"output" => elem(Agent.get(runs, & &1[id]), 1)})
          end

        {"GET", "/api/fs/read/" <> path} ->
          Plug.Conn.send_resp(conn, 200, File.read!(Path.join(at, URI.decode(path))))

        {"POST", "/api/experimental/fs/write"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          path = URI.decode_query(conn.query_string)["path"]
          File.write!(Path.join(at, path), body)
          data(conn, %{})

        {"GET", "/api/session"} ->
          data(conn, [session])

        {"GET", "/api/session/s1"} ->
          data(conn, session)

        {"POST", "/api/session/s1/prompt"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(told, &(&1 ++ [Jason.decode!(body)["text"]]))
          data(conn, %{})

        {"POST", "/api/session/s1/interrupt"} ->
          data(conn, %{})
      end
    end)

    project = project_fixture(%{name: "q", directory: main}, nil)
    Projects.record_session("s1", project, nil)
    %{project: project, wt: wt, told: told}
  end

  defp tree(project, ref) do
    {:ok, board} = TaskQueue.board(project, nil)
    Enum.find(board.trees, &(&1.ref == ref))
  end

  defp status(tree, id), do: Enum.find(tree.tickets, &(&1["id"] == id))

  test "queued tasks go to the chat's worktree; the first starts while the chat is free", %{
    project: project,
    told: told
  } do
    assert {:ok, [a, b]} =
             TaskQueue.add(project, nil, "s1", ["Replace fixed waits", "Report CI retries"], true)

    wt = tree(project, "s1")
    assert wt.worktree == "brave-lagoon"
    assert wt.chat.id == "s1"
    assert status(wt, a)["status"] == "in_progress"
    assert status(wt, b)["blocked_by"] == [a]
    assert [prompt] = Agent.get(told, & &1)
    assert prompt =~ "Work on #{a}: Replace fixed waits"
    assert prompt =~ "tk close #{a}"

    # Main has none of them.
    assert tree(project, "main").tickets == []
  end

  test "closing a task starts the next ready one; a paused one waits", %{
    project: project,
    told: told
  } do
    {:ok, project} = Projects.update_settings(project, %{queue_auto: false})
    assert {:ok, [a, b, c]} = TaskQueue.add(project, nil, "s1", ["One", "Two", "Three"])
    assert Agent.get(told, & &1) == []

    assert {:ok, "s1"} = TaskQueue.start(project, nil, "s1", a)
    assert {:error, msg} = TaskQueue.start(project, nil, "s1", b)
    assert msg =~ "#{a} is running"

    assert :ok = TaskQueue.pause(project, nil, "s1", a)
    wt = tree(project, "s1")
    assert status(wt, a)["paused"]
    assert status(wt, a)["status"] == "open"

    {:ok, project} = Projects.update_settings(project, %{queue_auto: true})
    assert {:ok, "s1"} = TaskQueue.start(project, nil, "s1", b)
    assert :ok = TaskQueue.done(project, nil, "s1", b)

    # a is paused, so c goes next.
    wt = tree(project, "s1")
    assert status(wt, b)["status"] == "closed"
    assert status(wt, c)["status"] == "in_progress"
    assert List.last(Agent.get(told, & &1)) =~ "Work on #{c}"
  end

  test "edits a task's file and its deps", %{project: project, wt: wt} do
    {:ok, project} = Projects.update_settings(project, %{queue_auto: false})
    assert {:ok, [a, b]} = TaskQueue.add(project, nil, "s1", ["One", "Two"])
    {:ok, tree} = TaskQueue.tree(project, nil, "s1")

    assert :ok = Tickets.edit(tree, a, %{"title" => "Uno", "body" => "Why", "priority" => 0})
    assert :ok = Tickets.dep(tree, b, a, true)

    t = tree(project, "s1")
    assert %{"title" => "Uno", "body" => "Why", "priority" => 0} = status(t, a)
    assert status(t, b)["blocked_by"] == [a]

    assert :ok = Tickets.delete(tree, b)
    refute File.exists?(Path.join(wt, ".tickets/#{b}.md"))
  end
end
