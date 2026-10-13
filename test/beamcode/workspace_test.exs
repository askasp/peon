defmodule Beamcode.WorkspaceTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ConnCase, only: [user_fixture: 1]
  alias Beamcode.Workspace

  setup do
    test = self()

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"GET", "/api/fs/read/" <> _} ->
          Plug.Conn.send_resp(conn, 404, "")

        {"POST", "/api/experimental/fs/write"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          dir = conn.query_params["location"]["directory"]
          send(test, {:wrote, Path.join(dir, conn.query_params["path"]), body})
          data(conn, %{})

        {"GET", "/api/location"} ->
          Req.Test.json(conn, %{"directory" => "/tmp/chatos-test"})

        _ ->
          data(conn, [])
      end
    end)

    %{user: user_fixture(%{"username" => "marte.h_2"})}
  end

  test "each user gets one private Home folder", %{user: user} do
    assert {:ok, home} = Workspace.ensure_home(user)
    assert %{name: "home-marte-h-2", kind: "home", scope: "private"} = home
    assert home.directory == "/tmp/chatos-test/home/marte-h-2"
    assert_received {:wrote, "/tmp/chatos-test/home/marte-h-2/AGENTS.md", "# Chat" <> _}

    assert {:ok, again} = Workspace.ensure_home(user)
    assert again.id == home.id
  end

  test "a Design folder starts with design instructions and a skill", %{user: user} do
    assert {:ok, project} =
             Workspace.create_project(%{"name" => "site", "kind" => "design"}, user)

    assert project.directory == "/tmp/chatos-test/site"
    assert_received {:wrote, "/tmp/chatos-test/site/AGENTS.md", "# Designs" <> _}
    assert_received {:wrote, "/tmp/chatos-test/site/.opencode/skill/html-design/SKILL.md", _}
  end

  test "the Procedures section Peon wrote is kept current, the rest stays" do
    test = self()

    old =
      "# ops\n\nOur notes.\n\n## Procedures\n\nA procedure is one file, an old text.\n\n" <>
        "### Blocks\n\nOld.\n\n## Tone\n\nBe brief.\n"

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/fs/read/AGENTS.md"} ->
          Plug.Conn.send_resp(conn, 200, old)

        {"POST", "/api/experimental/fs/write"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:wrote, body})
          data(conn, %{})
      end
    end)

    project = %Beamcode.Projects.Project{directory: "/srv/ops", kind: "routine"}
    Workspace.refresh_conventions(project)
    assert_received {:wrote, new}
    assert new =~ "# ops\n\nOur notes.\n\n## Procedures\n\nA procedure is one file"
    assert new =~ "### Since the last run"
    assert String.ends_with?(new, "\n\n## Tone\n\nBe brief.\n")
    refute new =~ "an old text"
  end
end
