defmodule BeamcodeWeb.FileControllerTest do
  use BeamcodeWeb.ConnCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias BeamcodeWeb.FileToken

  setup do
    admin = user_fixture(%{"username" => "aksel"})
    user = user_fixture(%{"username" => "marte"})
    app = project_fixture(%{name: "app"}, admin)
    notes = project_fixture(%{name: "notes", kind: "chat", scope: "private"}, admin)

    setup_stub(fn conn ->
      case conn.request_path do
        "/api/fs/read/designs/home.html" -> Plug.Conn.send_resp(conn, 200, "<h1>Home</h1>")
        _ -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    %{admin: admin, user: user, app: app, notes: notes}
  end

  test "serves a file sandboxed under a valid token", %{conn: conn, user: user, app: app} do
    conn = get(conn, FileToken.base(user, app) <> "designs/home.html")
    assert conn.status == 200
    assert conn.resp_body =~ "<h1>Home</h1>"
    # Pages get peon.query for the folder's data.
    assert conn.resp_body =~ "window.peon="
    assert get_resp_header(conn, "content-type") == ["text/html"]
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "sandbox"
    refute csp =~ "allow-same-origin"
  end

  test "refuses bad tokens, hidden projects and missing files", %{
    conn: conn,
    user: user,
    app: app,
    notes: notes
  } do
    assert get(conn, "/files/nope/designs/home.html").status == 401
    # A private project the user can't see.
    assert get(conn, FileToken.base(user, notes) <> "designs/home.html").status == 401
    assert get(conn, FileToken.base(user, app) <> "missing.html").status == 404
    assert post(conn, "/files/nope/_query", %{sql: "select 1"}).status == 401
    assert post(conn, FileToken.base(user, app) <> "_query", %{}).status == 400
  end
end
