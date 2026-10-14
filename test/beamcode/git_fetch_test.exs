defmodule Beamcode.GitFetchTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.{GitFetch, Sessions}

  @moduletag :tmp_dir

  defp git(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit(dir, file) do
    File.write!(Path.join(dir, file), file)
    git(dir, ["add", "."])
    git(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", file])
    git(dir, ["rev-parse", "HEAD"])
  end

  # A bare origin, the Project's folder cloned from it, and a second clone
  # standing in for a teammate who pushes. OpenCode's shell runs for real; its
  # worktrees are made with git, detached, at the ref asked for.
  setup %{tmp_dir: tmp} do
    origin = Path.join(tmp, "origin.git")
    other = Path.join(tmp, "other")
    repo = Path.join(tmp, "repo")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", origin])
    {_, 0} = System.cmd("git", ["clone", "-q", origin, other], stderr_to_stdout: true)
    git(other, ["checkout", "-q", "-b", "main"])
    first = commit(other, "a.txt")
    git(other, ["push", "-q", "origin", "main"])
    {_, 0} = System.cmd("git", ["clone", "-q", origin, repo], stderr_to_stdout: true)

    runs = start_supervised!({Agent, fn -> %{} end})
    test = self()

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          command = Jason.decode!(body)["command"]
          if command =~ "git fetch", do: send(test, :fetched)
          {out, code} = System.cmd("sh", ["-c", command], cd: repo, stderr_to_stdout: true)
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
          ref = Jason.decode!(body)["branch"]
          dir = Path.join(tmp, "wt#{System.unique_integer([:positive])}")
          git(repo, ["worktree", "add", "-q", "--detach", dir, ref || "HEAD"])
          send(test, {:worktree, ref})
          data(conn, %{"directory" => dir})

        {"POST", "/api/session"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          dir = get_in(Jason.decode!(body), ["location", "directory"])
          data(conn, %{"id" => "ses_1", "directory" => dir})
      end
    end)

    project =
      project_fixture(%{name: "app", directory: repo}, nil)
      |> Ecto.Changeset.change(kind: "code", oc_project_id: "prj_1")
      |> Beamcode.Repo.update!()

    %{project: project, repo: repo, other: other, first: first}
  end

  test "a new worktree chat starts from what was pushed since the folder was pulled", %{
    project: project,
    repo: repo,
    other: other,
    first: first
  } do
    pushed = commit(other, "b.txt")
    git(other, ["push", "-q", "origin", "main"])

    {:ok, session} = Sessions.start(project, nil, worktree: true)

    assert_received :fetched
    assert_received {:worktree, ^pushed}
    assert git(session["directory"], ["rev-parse", "HEAD"]) == pushed
    # The folder's own checkout is left where it was.
    assert git(repo, ["rev-parse", "HEAD"]) == first
  end

  test "fetches again only when the last fetch is over a minute old", %{project: project} do
    assert GitFetch.base(project)
    assert_received :fetched
    assert GitFetch.base(project)
    refute_received :fetched
  end

  test "unpushed commits in the folder's checkout are kept", %{project: project, repo: repo} do
    local = commit(repo, "local.txt")
    assert GitFetch.base(project) == local
  end

  test "a folder without a remote leaves the base to OpenCode", %{project: project, repo: repo} do
    git(repo, ["remote", "remove", "origin"])
    assert GitFetch.fetch(project) == :ok
    assert GitFetch.base(project) == nil
  end
end
