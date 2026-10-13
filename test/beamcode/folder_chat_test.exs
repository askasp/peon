defmodule Beamcode.FolderChatTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  import BeamcodeWeb.ConnCase, only: [user_fixture: 0]
  alias Beamcode.{Projects, Sessions}

  # An OpenCode holding `sessions`, which makes new ones on POST.
  defp stub_sessions(sessions) do
    store = start_supervised!({Agent, fn -> sessions end})

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/session"} ->
          data(conn, Agent.get(store, & &1))

        {"POST", "/api/session"} ->
          s = %{"id" => "new", "title" => "made", "time" => %{"created" => 9, "updated" => 9}}
          Agent.update(store, &[s | &1])
          data(conn, s)
      end
    end)

    store
  end

  defp session(id, created, updated),
    do: %{"id" => id, "title" => id, "time" => %{"created" => created, "updated" => updated}}

  setup do
    user = user_fixture()
    %{user: user, project: project_fixture(%{name: "site", kind: "design"}, user)}
  end

  test "a Project's one chat is made once, then found again", %{user: user, project: project} do
    store = stub_sessions([])

    assert {:ok, %{"id" => "new"}, []} = Sessions.folder_chat(project, user)
    assert {:ok, %{"id" => "new"}, []} = Sessions.folder_chat(project, user)
    assert length(Agent.get(store, & &1)) == 1
  end

  test "the chat worked in last is the one chat; the others come back oldest first",
       %{user: user, project: project} do
    stub_sessions([session("b", 2, 50), session("a", 1, 10), session("c", 3, 20)])

    assert {:ok, %{"id" => "b"}, earlier} = Sessions.folder_chat(project, user)
    assert Enum.map(earlier, & &1["id"]) == ["a", "c"]
  end

  test "someone's private chat is never the shared one", %{user: user, project: project} do
    stub_sessions([session("mine", 1, 99), session("shared", 2, 10)])
    Projects.record_session("mine", project, user, scope: "private")

    assert {:ok, %{"id" => "shared"}, [%{"id" => "mine"}]} = Sessions.folder_chat(project, user)
  end

  test "new work in a single-chat Project goes to its chat; code still starts one",
       %{user: user, project: project} do
    stub_sessions([session("one", 1, 1)])
    assert {:ok, %{"id" => "one"}} = Sessions.open(project, user)

    code = project_fixture(%{name: "app", kind: "code"}, user)
    assert {:ok, %{"id" => "new"}} = Sessions.open(code, user)
  end

  test "each Operations run gets its own chat, a batch as one message", %{user: user} do
    folder = project_fixture(%{name: "amino-maintenance", kind: "routine"}, user)
    sent = start_supervised!({Agent, fn -> [] end})
    made = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :made))

    setup_stub(fn conn ->
      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"GET", ["api", "session"]} ->
          data(conn, [session("chat", 1, 1)])

        {"POST", ["api", "session"]} ->
          n = Agent.get_and_update(made, &{&1 + 1, &1 + 1})
          data(conn, session("r#{n}", n, n))

        {"GET", ["api", "skill"]} ->
          path = folder.directory <> "/.opencode/skill/refund/SKILL.md"
          data(conn, [%{"name" => "refund", "id" => "refund", "path" => path}])

        {"GET", ["api", "fs", "read", "procedures.json"]} ->
          Plug.Conn.send_resp(conn, 200, ~s({"refund": {"key": "charge"}}))

        {"POST", ["api", "session", sid, "prompt"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(sent, &[{sid, Jason.decode!(body)} | &1])
          data(conn, %{})

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    rows = [%{"charge" => "ch_1", "name" => "Ola"}, %{"charge" => "ch_2", "name" => "Kari"}]
    alias Beamcode.Procedures.Runs
    assert {:ok, %{session_id: "r1"}} = Runs.start(folder, user, "refund", rows)
    assert {:ok, %{session_id: "r2"}} = Runs.start(folder, user, "refund", %{"charge" => "ch_3"})
    assert {:error, "No procedure called nope."} = Runs.start(folder, user, "nope", %{})

    assert [
             {"r2", %{"skills" => [%{"id" => "refund"}], "text" => "charge: ch_3"}},
             {"r1",
              %{
                "text" =>
                  "Run this once for each row, in order:\n- charge: ch_1, name: Ola\n- charge: ch_2, name: Kari"
              }}
           ] = Agent.get(sent, & &1)

    # They're run chats about refund, kept out of the Project's chat list.
    assert %{chat: "run", procedure: "refund"} = Projects.session_record("r1")
    Projects.record_session("chat", folder, user)
    {:ok, listed} = Sessions.list_visible(folder, user)
    assert Enum.map(listed, & &1["id"]) == ["chat"]
  end
end
