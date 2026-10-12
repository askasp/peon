defmodule BeamcodeWeb.AppChannelTest do
  use BeamcodeWeb.ChannelCase, async: false

  import Beamcode.OpencodeStub
  alias Beamcode.Projects
  alias BeamcodeWeb.UserSocket

  setup do
    admin = user_fixture(%{"username" => "aksel"})
    user = user_fixture(%{"username" => "marte"})
    app = project_fixture(%{name: "app"}, admin)
    _notes = project_fixture(%{name: "notes", kind: "chat", scope: "private"}, admin)

    {:ok, socket} = connect(UserSocket, token_params(user))
    %{admin: admin, user: user, app: app, socket: socket}
  end

  defp join(socket) do
    {:ok, reply, socket} = subscribe_and_join(socket, "app", %{})
    {reply, socket}
  end

  test "joining lists the projects the user can see", %{socket: socket} do
    {reply, _socket} = join(socket)
    assert reply.user.username == "marte"
    assert Enum.map(reply.projects, & &1.name) == ["app"]
  end

  test "sessions leave out other people's private ones", %{socket: socket, app: app, admin: admin} do
    Projects.record_session("ses_private", app, admin, scope: "private")
    Projects.record_session("ses_team", app, admin)

    setup_stub(fn conn ->
      assert conn.request_path == "/api/session"

      data(conn, [
        %{"id" => "ses_private", "title" => "Secret", "time" => %{"updated" => 2}},
        %{"id" => "ses_team", "title" => "Fix checkout", "time" => %{"updated" => 3}},
        %{"id" => "ses_old", "title" => "Old", "time" => %{"updated" => 1}},
        %{"id" => "ses_child", "parentID" => "ses_team", "time" => %{"updated" => 4}}
      ])
    end)

    {_, socket} = join(socket)
    ref = push(socket, "sessions", %{"project_id" => app.id})
    assert_reply ref, :ok, %{sessions: sessions}
    assert Enum.map(sessions, & &1.id) == ["ses_team", "ses_old"]
    assert hd(sessions).started_by == "aksel"
  end

  test "a project the user can't see is not found", %{socket: socket} do
    notes = Enum.find(Projects.list_projects(), &(&1.name == "notes"))
    {_, socket} = join(socket)
    ref = push(socket, "sessions", %{"project_id" => notes.id})
    assert_reply ref, :error, %{message: "Project not found."}
  end

  test "new_session starts a session and sends the first message", %{socket: socket, app: app} do
    test = self()

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/session"} ->
          data(conn, %{"id" => "ses_new", "location" => %{"directory" => "/srv/app"}})

        {"POST", "/api/session/ses_new/prompt"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:prompt, Jason.decode!(body)})
          data(conn, %{})
      end
    end)

    {_, socket} = join(socket)
    ref = push(socket, "new_session", %{"project_id" => app.id, "text" => "find the bug"})
    assert_reply ref, :ok, %{session_id: "ses_new"}
    assert_received {:prompt, %{"text" => "find the bug"}}
    assert Projects.session_record("ses_new").project_id == app.id
  end

  test "permission replies only for sessions the user can see", %{
    socket: socket,
    app: app,
    admin: admin
  } do
    Projects.record_session("ses_private", app, admin, scope: "private")
    Projects.record_session("ses_team", app, admin)
    test = self()

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/session/" <> id} ->
          data(conn, %{"id" => id, "location" => %{"directory" => "/srv/app"}})

        {"POST", path} ->
          send(test, {:replied, path})
          no_content(conn)
      end
    end)

    {_, socket} = join(socket)

    ref =
      push(socket, "permission", %{
        "session_id" => "ses_private",
        "id" => "per_1",
        "decision" => "once"
      })

    assert_reply ref, :error, %{message: "Session not found, or not yours to see."}
    refute_received {:replied, _}

    ref =
      push(socket, "permission", %{
        "session_id" => "ses_team",
        "id" => "per_2",
        "decision" => "always"
      })

    assert_reply ref, :ok, %{}
    assert_received {:replied, "/api/session/ses_team/permission/per_2/reply"}
  end

  test "shortcuts and the keymap are saved without losing each other", %{
    socket: socket,
    user: user
  } do
    {_, socket} = join(socket)

    ref = push(socket, "save_keys", %{"binds" => %{"model_list" => "ctrl+m"}})
    assert_reply ref, :ok, %{keys: _}
    assert Beamcode.Accounts.get_user(user.id).keybinds == %{"model_list" => "ctrl+m"}

    prefs = %{"keymap" => "standard", "prefix" => "ctrl+a", "status_line" => false}
    ref = push(socket, "save_keys", %{"prefs" => prefs})
    assert_reply ref, :ok, %{keys: _}

    assert Beamcode.Accounts.get_user(user.id).keybinds ==
             Map.put(prefs, "model_list", "ctrl+m")

    # Reset shortcuts: the keymap stays.
    ref = push(socket, "save_keys", %{"binds" => %{}})
    assert_reply ref, :ok, %{keys: _}
    assert Beamcode.Accounts.get_user(user.id).keybinds == prefs
  end

  test "system projects can't be created from the app", %{socket: socket} do
    {_, socket} = join(socket)
    ref = push(socket, "create_project", %{"params" => %{"kind" => "system", "name" => "x"}})
    assert_reply ref, :error, %{message: "Pick a template."}
  end

  test "the composer previews what a line will do", %{socket: socket} do
    {_, socket} = join(socket)
    ref = push(socket, "compose:preview", %{"text" => "new session in app, fix the login page"})
    assert_reply ref, :ok, %{preview: preview}
    assert preview.action == "session"
    assert ["Project", "app"] in preview.rows
  end

  test "session activity is pushed", %{socket: socket} do
    {_, _socket} = join(socket)

    Phoenix.PubSub.broadcast(
      Beamcode.PubSub,
      "oc:activity",
      {:oc_activity, "session.execution.started", %{"sessionID" => "ses_team"}}
    )

    assert_push "activity", %{type: "session.execution.started", session_id: "ses_team"}
    assert_push "inbox", %{items: []}
  end
end
