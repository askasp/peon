defmodule Beamcode.BranchGuardTest do
  use Beamcode.DataCase, async: false
  import Beamcode.OpencodeStub
  alias Beamcode.{Accounts, BranchGuard, Projects, Sessions}

  setup do
    test = self()

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          command = Jason.decode!(body)["command"]
          send(test, {:shell, command})
          data(conn, %{"id" => "sh_" <> Base.url_encode64(command, padding: false)})

        {"GET", "/api/shell/" <> rest} ->
          case String.split(rest, "/") do
            [_id] ->
              data(conn, %{"status" => "exited", "exit" => 0})

            [id, "output"] ->
              command = id |> String.trim_leading("sh_") |> Base.url_decode64!(padding: false)
              out = if command =~ "symbolic-ref", do: "origin/develop\n", else: ""
              data(conn, %{"output" => out})
          end

        {"GET", "/api/session"} ->
          data(conn, [%{"id" => "ses_old"}])

        {"PATCH", "/api/session/" <> id} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:patch, id, Jason.decode!(body)})
          data(conn, %{"id" => id})

        {"POST", "/api/session"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:create, Jason.decode!(body)})
          data(conn, %{"id" => "ses_new"})

        _ ->
          Plug.Conn.send_resp(conn, 404, "{}")
      end
    end)

    {:ok, user} = Accounts.create_user(%{"username" => "aksel", "password" => "password123"})

    {:ok, project} =
      Projects.insert_project(%{name: "app", kind: "code", directory: "/srv/oc/code/app"}, user)

    %{user: user, project: project}
  end

  test "rules deny pushes to each branch and merging PRs, nothing else" do
    resources = Enum.map(BranchGuard.rules(["main"]), & &1["resource"])

    assert "git push * main" in resources
    assert "git push * main *" in resources
    assert "git push *:main" in resources
    assert "git push *:refs/heads/main" in resources
    assert "gh pr merge*" in resources
    assert Enum.all?(BranchGuard.rules(["main"]), &(&1["effect"] == "deny"))
    refute Enum.any?(resources, &(&1 =~ "feature"))
  end

  test "turning it on installs the hook, learns the default branch and updates sessions",
       ctx do
    {:ok, project} = Projects.update_settings(ctx.project, %{protect_default_branch: true})
    assert {:ok, project} = BranchGuard.sync(project)

    assert project.default_branch == "develop"
    assert BranchGuard.branches(project) == ["main", "master", "develop"]

    assert_received {:shell, "git symbolic-ref" <> _}
    assert_received {:shell, install}
    assert install =~ "git rev-parse --git-path hooks"
    assert install =~ ~s(protected="main master develop")
    assert install =~ "pre-push.peon-orig"

    assert_received {:patch, "ses_old", %{"permissions" => rules}}
    assert %{"action" => "bash", "resource" => "git push * develop", "effect" => "deny"} in rules
  end

  test "turning it off removes the hook and clears session rules", ctx do
    assert {:ok, _} = BranchGuard.sync(ctx.project)

    assert_received {:shell, remove}
    assert remove =~ "rm \"$hooks/pre-push\""
    assert_received {:patch, "ses_old", %{"permissions" => []}}
  end

  test "new sessions in a protected project get the deny rules", ctx do
    {:ok, _} = Sessions.start(ctx.project, ctx.user)
    assert_received {:create, body}
    refute Map.has_key?(body, "permissions")

    {:ok, project} = Projects.update_settings(ctx.project, %{protect_default_branch: true})
    {:ok, _} = Sessions.start(project, ctx.user)
    assert_received {:create, %{"permissions" => [_ | _] = rules}}
    assert %{"action" => "bash", "resource" => "git push * main", "effect" => "deny"} in rules
  end

  test "the hook only blocks protected branches" do
    hook = BranchGuard.hook(["main", "master"])
    dir = Path.join(System.tmp_dir!(), "peon-hook-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "pre-push")
    File.write!(path, hook)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)

    push = fn ref ->
      input = "refs/heads/x abc #{ref} def\n"

      System.cmd("sh", ["-c", "printf '%s' \"$1\" | \"$2\" origin url", "sh", input, path],
        stderr_to_stdout: true
      )
    end

    assert {out, 1} = push.("refs/heads/main")
    assert out =~ "pushing to 'main' is blocked"
    assert {_, 1} = push.("refs/heads/master")
    assert {_, 0} = push.("refs/heads/feature/main-fix")
  end
end
