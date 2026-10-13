defmodule Beamcode.WorktreesTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.Worktrees

  @moduletag :tmp_dir

  defp git(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  # A repo with one commit, and an OpenCode whose shell runs in it.
  setup %{tmp_dir: dir} do
    git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "a.txt"), "a")
    git(dir, ["add", "."])
    git(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one"])
    runs = start_supervised!({Agent, fn -> %{} end})

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          {out, code} =
            System.cmd("sh", ["-c", Jason.decode!(body)["command"]],
              cd: dir,
              stderr_to_stdout: true
            )

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
      end
    end)

    %{project: project_fixture(%{name: "wt", directory: dir}, nil)}
  end

  defp worktree(dir, name) do
    wt = Path.join(System.tmp_dir!(), "peon-wt-#{System.unique_integer([:positive])}-#{name}")
    git(dir, ["worktree", "add", "-q", "-b", name, wt])
    on_exit(fn -> File.rm_rf(wt) end)
    wt
  end

  test "changes: committed and untracked files; none when fresh or merged", %{
    project: project,
    tmp_dir: dir
  } do
    busy = worktree(dir, "busy")
    fresh = worktree(dir, "fresh")
    merged = worktree(dir, "merged")

    File.write!(Path.join(busy, "a.txt"), "changed")
    git(busy, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "two"])
    File.write!(Path.join(busy, "new file.md"), "new")

    File.write!(Path.join(merged, "b.txt"), "b")
    git(merged, ["add", "."])
    git(merged, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "b"])
    git(dir, ["merge", "-q", "--ff-only", "merged"])

    changes = Worktrees.changes(project, [busy, fresh, merged])
    assert changes[busy] == ["a.txt", "new file.md"]
    assert changes[fresh] == []
    assert changes[merged] == []
  end

  test "main is its own folder; a Code Project's main is read-only", %{project: project} do
    assert {:ok, ^project} = Worktrees.at(project, nil, "main")
    assert Worktrees.code_main?(project, project)
    refute Worktrees.code_main?(%{project | directory: "/elsewhere"}, project)
    refute Worktrees.code_main?(%{project | kind: "design"}, %{project | kind: "design"})
  end
end
