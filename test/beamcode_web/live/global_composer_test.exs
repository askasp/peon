defmodule BeamcodeWeb.GlobalComposerTest do
  use BeamcodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Beamcode.OpencodeStub
  alias Beamcode.Projects

  setup %{conn: conn} do
    test = self()
    user = user_fixture()

    {:ok, _} =
      Projects.insert_project(
        %{"name" => "amino-monorepo", "kind" => "code", "directory" => "/srv/amino"},
        user
      )

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/session"} ->
          data(conn, %{"id" => "ses_1", "location" => %{"directory" => "/srv/amino"}})

        {"POST", "/api/session/ses_1/prompt"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:prompt, Jason.decode!(body)})
          data(conn, %{"id" => "msg_1"})

        {"GET", "/api/skill"} ->
          data(conn, [%{"id" => "e2e-debug", "name" => "e2e-debug"}])

        _ ->
          data(conn, [])
      end
    end)

    %{conn: log_in_user(conn, user)}
  end

  test "previews how the line reads", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    refute has_element?(view, "#global-composer-preview")

    view
    |> form("#global-composer-form",
      text: "new session in amino monorepo, use the e2e debug skill and then fix checkout"
    )
    |> render_change()

    assert has_element?(view, "#gc-action", "New session")
    assert has_element?(view, "#gc-project", "amino-monorepo")
    assert has_element?(view, "#gc-skill", "e2e-debug")
    assert has_element?(view, "#gc-task", "fix checkout")
    assert has_element?(view, "#gc-submit", "Start session")
  end

  test "starts the session, runs the skill and opens it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#global-composer-form",
      text: "new session in amino monorepo, use the e2e debug skill and then fix checkout"
    )
    |> render_submit()

    assert_redirect(view, ~p"/s/ses_1", 1000)
    assert_received {:prompt, %{"text" => "fix checkout", "skills" => [%{"id" => "e2e-debug"}]}}
  end

  test "a line with no project and no chat project asks for one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> form("#global-composer-form", text: "write me a haiku") |> render_change()
    assert has_element?(view, "#gc-project", "Pick a project")
    assert has_element?(view, "[id^=gc-pick-]", "@amino-monorepo")

    view |> form("#global-composer-form", text: "write me a haiku") |> render_submit()
    assert render(view) =~ "Say which project"
  end
end
