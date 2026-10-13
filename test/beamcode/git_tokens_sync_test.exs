defmodule Beamcode.GitTokensSyncTest do
  use Beamcode.DataCase, async: false
  import Beamcode.OpencodeStub
  alias Beamcode.{Accounts, GitTokens, Projects, Vault}

  @home_dir "/home/oc/.config/opencode-git"

  setup do
    test = self()

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"GET", "/api/location"} ->
          Req.Test.json(conn, %{"directory" => "/srv/oc"})

        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          command = Jason.decode!(body)["command"]
          send(test, {:shell, conn.query_params["location"]["directory"], command})
          data(conn, %{"id" => "sh_" <> Base.url_encode64(command, padding: false)})

        {"GET", "/api/shell/" <> rest} ->
          case String.split(rest, "/") do
            [_id] ->
              data(conn, %{"status" => "exited", "exit" => 0})

            [id, "output"] ->
              command = id |> String.trim_leading("sh_") |> Base.url_decode64!(padding: false)
              out = if command =~ "printf", do: @home_dir, else: ""
              data(conn, %{"output" => out})
          end

        {"GET", "/api/fs/read/tokens.local"} ->
          Plug.Conn.send_resp(conn, 404, "")

        {"POST", "/api/experimental/fs/write"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            test,
            {:write, conn.query_params["location"]["directory"], conn.query_params["path"], body}
          )

          data(conn, %{"path" => conn.query_params["path"]})
      end
    end)

    Req.Test.stub(Beamcode.GitTokens, fn conn ->
      send(test, {:github, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})

      if conn.request_path == "/repos/org/app",
        do: Req.Test.json(conn, %{"full_name" => "org/app"}),
        else: Plug.Conn.send_resp(conn, 404, "{}")
    end)

    {:ok, user} = Accounts.create_user(%{"username" => "aksel", "password" => "password123"})

    {:ok, project} =
      Projects.insert_project(
        %{name: "app", kind: "code", directory: "/srv/oc/code/app", github_repo: "org/app"},
        user
      )

    %{user: user, project: project}
  end

  test "saving a token checks it, stores it and writes the server's token file", ctx do
    assert {:ok, _} = GitTokens.save(ctx.project, " github_pat_abc \n", ctx.user)

    assert_received {:github, "/repos/org/app", ["Bearer github_pat_abc"]}
    assert Vault.fetch(ctx.project, "GIT_TOKEN") == {:ok, "github_pat_abc"}

    assert_received {:write, @home_dir, "tokens.local", content}
    assert content =~ "\norg/app github_pat_abc\n"
    assert_received {:shell, @home_dir, "chmod 600 tokens.local"}
  end

  test "a token that can't see the repo is refused and not stored", ctx do
    {:ok, other} =
      Projects.insert_project(
        %{name: "other", kind: "code", directory: "/srv/oc/code/other", github_repo: "org/other"},
        ctx.user
      )

    assert GitTokens.save(other, "github_pat_abc", ctx.user) ==
             {:error, "the token can't see org/other"}

    assert Vault.fetch(other, "GIT_TOKEN") == :error
    refute_received {:write, _, _, _}
  end

  test "removing a token rewrites the file without it", ctx do
    {:ok, _} = GitTokens.save(ctx.project, "github_pat_abc", ctx.user)
    assert :ok = GitTokens.delete(ctx.project)
    assert Vault.fetch(ctx.project, "GIT_TOKEN") == :error
  end
end
