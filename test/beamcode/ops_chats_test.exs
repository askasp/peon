defmodule Beamcode.OpsChatsTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  import BeamcodeWeb.ConnCase, only: [user_fixture: 0]
  alias Beamcode.{OpsChats, Projects, Repo}
  alias Beamcode.Schedules.Run

  @weekly """
  ---
  name: weekly-refunds
  schedule: { at: "Mon 07:00" }
  ---
  Find refunds.
  """

  # A fake OpenCode: sessions made on POST (s1, s2, …), files in an Agent, and
  # each session's messages.
  setup do
    user = user_fixture()
    project = project_fixture(%{name: "front", kind: "routine"}, user)
    oc = start_supervised!({Agent, fn -> %{n: 0, files: %{}, messages: %{}, titles: %{}} end})

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"POST", ["api", "session"]} ->
          n = Agent.get_and_update(oc, &{&1.n + 1, %{&1 | n: &1.n + 1}})
          data(conn, %{"id" => "s#{n}", "title" => "t", "time" => %{"created" => n}})

        {"GET", ["api", "session", sid, "message"]} ->
          data(conn, Agent.get(oc, & &1.messages[sid]) || [])

        {"PATCH", ["api", "session", sid]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(oc, &put_in(&1.titles[sid], Jason.decode!(body)["title"]))
          data(conn, %{"id" => sid})

        {"GET", ["api", "session", sid]} ->
          data(conn, %{"id" => sid, "time" => %{}})

        {"GET", ["api", "fs", "list"]} ->
          path = conn.query_params["path"]

          data(
            conn,
            for(
              f <- Agent.get(oc, &Map.keys(&1.files)),
              Path.dirname(f) == path,
              do: %{"path" => f, "type" => "file"}
            )
          )

        {"GET", ["api", "fs", "read" | rest]} ->
          case Agent.get(oc, & &1.files[Enum.join(rest, "/")]) do
            nil -> Plug.Conn.send_resp(conn, 404, "")
            body -> Plug.Conn.send_resp(conn, 200, body)
          end

        {"POST", ["api", "experimental", "fs", "write"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(oc, &put_in(&1.files[conn.query_params["path"]], body))
          data(conn, %{})

        _ ->
          data(conn, [])
      end
    end)

    %{user: user, project: project, oc: oc}
  end

  defp put_file(oc, path, body), do: Agent.update(oc, &put_in(&1.files[path], body))

  test "a procedure's chat is made once, then found again", %{user: user, project: project} do
    assert {:ok, "s1"} = OpsChats.procedure_chat(project, user, "refund-asks")
    assert {:ok, "s1"} = OpsChats.procedure_chat(project, user, "refund-asks")
    assert {:ok, "s2"} = OpsChats.procedure_chat(project, user, "refund")

    assert %{chat: "procedure", procedure: "refund-asks"} = Projects.session_record("s1")
  end

  test "a new procedure's chat takes the procedure it wrote, with its schedule paused",
       %{user: user, project: project, oc: oc} do
    {:ok, sid} = OpsChats.new_procedure_chat(project, user)
    record = Projects.session_record(sid)
    assert %{procedure: nil, new: true} = OpsChats.info(project, record)

    # The first message gets the instructions for a new one.
    assert OpsChats.with_context(project, record, "Every Monday…") =~
             ~r/Every Monday…\n\n```peon-context\nThis chat makes a new procedure/

    put_file(oc, ".peon/procedures/weekly-refunds.md", @weekly)

    tool = fn name, path ->
      %{
        "type" => "tool",
        "name" => name,
        "state" => %{"status" => "completed", "input" => %{"filePath" => path}}
      }
    end

    Agent.update(
      oc,
      &put_in(&1.messages[sid], [
        %{
          "type" => "assistant",
          "content" => [
            tool.("edit", "/srv/front/AGENTS.md"),
            tool.("write", "/srv/front/.peon/procedures/weekly-refunds.md")
          ]
        }
      ])
    )

    # Opening the procedure finds the chat that wrote it, even before anyone looked.
    assert {:ok, ^sid} = OpsChats.procedure_chat(project, user, "weekly-refunds")

    assert %{procedure: "weekly-refunds", path: ".peon/procedures/weekly-refunds.md", new: true} =
             OpsChats.info(project, Projects.session_record(sid))

    assert Agent.get(oc, & &1.titles[sid]) == "weekly-refunds"
    assert Repo.reload!(project).paused_schedules == ["weekly-refunds"]
  end

  test "a message keeps the file as it was, and Undo puts it back",
       %{user: user, project: project, oc: oc} do
    put_file(oc, ".peon/procedures/refund-asks.md", "v1")
    {:ok, sid} = OpsChats.procedure_chat(project, user, "refund-asks")

    text = OpsChats.with_context(project, Projects.session_record(sid), "Skip vip threads")
    assert text =~ "about the procedure refund-asks (.peon/procedures/refund-asks.md)"
    assert %{base: "v1", new: false} = OpsChats.info(project, Projects.session_record(sid))

    put_file(oc, ".peon/procedures/refund-asks.md", "v2")
    assert {:ok, %{base: nil}} = OpsChats.undo(project, Projects.session_record(sid))
    assert Agent.get(oc, & &1.files[".peon/procedures/refund-asks.md"]) == "v1"
    assert {:error, _} = OpsChats.undo(project, Projects.session_record(sid))
  end

  test "a run chat knows its run and offers Edit instead of editing",
       %{user: user, project: project} do
    run =
      Repo.insert!(%Run{
        project_id: project.id,
        owner_id: user.id,
        schedule_key: "manual",
        procedure: "refund",
        trigger: "button",
        status: "failed",
        error: "400 charge_disputed",
        inputs: %{"charge" => "ch_3PyA"},
        steps: [%{"name" => "Refund", "status" => "failed", "error" => "charge_disputed"}]
      })

    # A run with only API calls has no chat until it's opened.
    assert {:ok, "s1"} = OpsChats.run_chat(project, user, run)
    assert {:ok, "s1"} = OpsChats.run_chat(project, user, Repo.reload!(run))

    text = OpsChats.with_context(project, Projects.session_record("s1"), "What happened?")
    assert text =~ "run #{run.id} of the procedure refund (failed: 400 charge_disputed)"
    assert text =~ "[Edit refund](edit:refund)"
    assert text =~ ~s(Inputs: {"charge":"ch_3PyA"})
    assert text =~ "- Refund: failed (charge_disputed)"
  end
end
