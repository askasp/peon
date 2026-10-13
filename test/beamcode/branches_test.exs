defmodule Beamcode.BranchesTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.Branches

  @moduletag :tmp_dir

  defp git(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  # A repo on main with a `feat/login` branch, and an OpenCode whose shell runs
  # in the folder asked for and whose worktrees are made with git, detached.
  setup %{tmp_dir: tmp} do
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "a.txt"), "a")
    git(repo, ["add", "."])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one"])
    git(repo, ["branch", "feat/login"])
    runs = start_supervised!({Agent, fn -> %{} end})
    test = self()

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          cd = get_in(conn.query_params, ["location", "directory"]) || repo
          command = Jason.decode!(body)["command"]
          send(test, {:shell, cd, command})
          {out, code} = System.cmd("sh", ["-c", command], cd: cd, stderr_to_stdout: true)
          id = "sh#{System.unique_integer([:positive])}"
          Agent.update(runs, &Map.put(&1, id, {code, out}))
          data(conn, %{"id" => id})

        {"GET", "/api/shell/" <> rest} ->
          case String.split(rest, "/") do
            [id] ->
              data(conn, %{"status" => "done", "exit" => elem(Agent.get(runs, & &1[id]), 0)})

            [id, "output"] ->
              data(conn, %{"output" => elem(Agent.get(runs, & &1[id]), 1)})
          end

        {"POST", "/api/worktree"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"branch" => ref, "name" => name} = Jason.decode!(body)
          dir = Path.join(tmp, name)
          git(repo, ["worktree", "add", "-q", "--detach", dir, ref])
          send(test, {:worktree, ref, name})
          data(conn, %{"directory" => dir})
      end
    end)

    project =
      project_fixture(%{name: "app", directory: repo}, nil)
      |> Ecto.Changeset.change(oc_project_id: "prj_1")
      |> Beamcode.Repo.update!()

    %{project: project, repo: repo, tmp: tmp}
  end

  test "lists the branches a chat can continue, without the Project's own", %{project: project} do
    assert {:ok, [%{name: "feat/login", worktree: nil, remote: false}]} = Branches.list(project)
  end

  test "a branch without a worktree gets one, checked out on the branch", %{
    project: project,
    tmp: tmp
  } do
    assert {:ok, dir} = Branches.directory(project, "feat/login")
    assert dir == Path.join(tmp, "feat-login")
    assert_received {:worktree, "feat/login", "feat-login"}
    {branch, 0} = System.cmd("git", ["-C", dir, "branch", "--show-current"])
    assert String.trim(branch) == "feat/login"

    # Next time it's opened, not made again; and the list says where it is.
    assert {:ok, ^dir} = Branches.directory(project, "feat/login")
    refute_received {:worktree, _, _}
    assert {:ok, [%{name: "feat/login", worktree: "feat-login"}]} = Branches.list(project)
  end

  test "names git could take as options are refused", %{project: project} do
    assert {:error, "Not a branch name."} = Branches.directory(project, "--force")
    assert {:error, "Not a branch name."} = Branches.directory(project, "a/../b")
  end
end
