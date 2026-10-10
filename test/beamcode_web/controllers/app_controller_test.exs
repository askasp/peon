defmodule BeamcodeWeb.AppControllerTest do
  use BeamcodeWeb.ConnCase, async: false

  alias BeamcodeWeb.AppToken

  setup do
    dir = Path.join(System.tmp_dir!(), "beamcode-app-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    index = Path.join(dir, "index.html")
    File.write!(index, "<html><head><title>Peon</title></head><body></body></html>")
    Application.put_env(:beamcode, :app_index, index)

    on_exit(fn ->
      Application.delete_env(:beamcode, :app_index)
      File.rm_rf!(dir)
    end)

    %{index: index}
  end

  test "logged out, the app sends you to log in and back", %{conn: conn} do
    conn = get(conn, ~p"/app/project/3")
    assert redirected_to(conn) == ~p"/login"
    assert get_session(conn, :user_return_to) == "/app/project/3"
  end

  test "every app path is the app's page with a socket token for the web login", %{conn: conn} do
    user = user_fixture()
    html = conn |> log_in_user(user) |> get(~p"/app/session/ses_1") |> html_response(200)

    [_, token] = Regex.run(~r/<meta name="peon-token" content="([^"]+)">/, html)
    assert {:ok, %{id: id}} = AppToken.verify(token)
    assert id == user.id
    assert html =~ ~s(<meta name="csrf-token")
  end

  test "says so when the web app isn't built", %{conn: conn, index: index} do
    File.rm!(index)
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/app")
    assert response(conn, 503) =~ "mix assets.deploy"
  end

  test "/ opens the app", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/app"
  end

  test "old LiveView addresses open the same page in the app", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    for {old, new} <- [
          {"/s/ses_1", "/app/session/ses_1"},
          {"/p/3", "/app/project/3"},
          {"/p/3/schedules", "/app/project/3?tab=schedules"},
          {"/p/3/nonsense", "/app/project/3"},
          {"/inbox", "/app"},
          {"/schedules", "/app/schedules"},
          {"/users", "/app/users"}
        ] do
      assert redirected_to(get(conn, old)) == new, old
    end

    assert response(get(conn, "/nonsense"), 404)
  end
end
