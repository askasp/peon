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

  test "a Folder's one chat is made once, then found again", %{user: user, project: project} do
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

  test "new work in a single-chat Folder goes to its chat; code still starts one",
       %{user: user, project: project} do
    stub_sessions([session("one", 1, 1)])
    assert {:ok, %{"id" => "one"}} = Sessions.open(project, user)

    code = project_fixture(%{name: "app", kind: "code"}, user)
    assert {:ok, %{"id" => "new"}} = Sessions.open(code, user)
  end
end
