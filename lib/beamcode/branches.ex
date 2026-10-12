defmodule Beamcode.Branches do
  @moduledoc """
  The git branches of a Code Folder a new chat can continue, and the folder a
  chat on one works in: the branch's worktree when it has one, else a new
  worktree with the branch checked out (`Beamcode.Sessions.start/3`).
  """
  alias Beamcode.Opencode
  alias Beamcode.Projects.Project

  @doc """
  Local branches, then remote ones with no local branch, newest commit first:
  `[%{name, worktree, remote, updated}]`. `worktree` is the folder name when
  the branch is checked out in one; the Folder's own branch is left out.
  """
  def list(%Project{kind: "code"} = project) do
    script =
      "git for-each-ref --sort=-committerdate " <>
        "--format='%(refname)%09%(worktreepath)%09%(committerdate:unix)' refs/heads refs/remotes"

    case Opencode.run_shell(project.directory, script, 30_000) do
      {:ok, 0, out} -> {:ok, parse(out, project.directory)}
      {:ok, _, out} -> {:error, String.trim(out)}
      error -> error
    end
  end

  def list(%Project{}), do: {:ok, []}

  defp parse(out, main_dir) do
    rows =
      for line <- String.split(out, "\n", trim: true),
          [ref, path, time] <- [String.split(line, "\t")],
          do: {ref, path, String.to_integer(time)}

    local =
      for {"refs/heads/" <> name, path, time} <- rows, path != main_dir do
        %{name: name, worktree: worktree_name(path), remote: false, updated: time * 1000}
      end

    taken = MapSet.new(for {"refs/heads/" <> name, _, _} <- rows, do: name)

    remote =
      for {"refs/remotes/" <> rest, _, time} <- rows,
          [_remote, name] <- [String.split(rest, "/", parts: 2)],
          name != "HEAD",
          not MapSet.member?(taken, name),
          uniq: true do
        %{name: name, worktree: nil, remote: true, updated: time * 1000}
      end

    Enum.sort_by(local ++ remote, &(-&1.updated))
  end

  defp worktree_name(""), do: nil
  defp worktree_name(path), do: Path.basename(path)

  @doc "Whether `name` is a branch name safe to hand to git."
  def valid?(name) when is_binary(name),
    do: Regex.match?(~r{^[\w][\w./-]*$}, name) and not String.contains?(name, "..")

  def valid?(_), do: false

  @doc """
  The folder a chat on `branch` works in: the worktree that has it checked out,
  or a new one (made by OpenCode, so it's listed with the others) switched to it.
  A branch only on the remote gets a local branch tracking it.
  """
  def directory(%Project{oc_project_id: nil} = project, _branch),
    do: {:error, "#{project.name} has no OpenCode project id yet"}

  def directory(%Project{} = project, branch) do
    if valid?(branch), do: find_or_create(project, branch), else: {:error, "Not a branch name."}
  end

  defp find_or_create(project, branch) do
    script =
      "git worktree list --porcelain; echo @@; " <>
        "git show-ref --verify -q #{q("refs/heads/" <> branch)} && echo local; true"

    with {:ok, 0, out} <- Opencode.run_shell(project.directory, script, 30_000) do
      [worktrees, rest] = String.split(out, "@@", parts: 2)

      case checked_out(worktrees, branch) do
        nil -> create(project, branch, String.contains?(rest, "local"))
        dir -> {:ok, dir}
      end
    else
      {:ok, _, out} -> {:error, String.trim(out)}
      error -> error
    end
  end

  # The worktree folder with `refs/heads/<branch>` checked out, from `git worktree list --porcelain`.
  defp checked_out(porcelain, branch) do
    porcelain
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.find_value(fn block ->
      lines = String.split(block, "\n", trim: true)

      if "branch refs/heads/" <> branch in lines,
        do: Enum.find_value(lines, &match?("worktree " <> _, &1) && String.trim_leading(&1, "worktree "))
    end)
  end

  defp create(project, branch, local?) do
    # OpenCode checks the worktree out detached; `git switch` puts it on the branch.
    ref = if local?, do: branch, else: "origin/" <> branch
    name = String.replace(branch, ~r/[^\w.-]+/, "-")

    with {:ok, %{"directory" => dir}} <-
           Opencode.create_worktree(project.oc_project_id, branch: ref, name: name),
         {:ok, 0, _} <- Opencode.run_shell(dir, "git switch -q #{q(branch)}", 60_000) do
      {:ok, dir}
    else
      {:ok, _, out} -> {:error, "Couldn't check out #{branch}: #{String.trim(out)}"}
      {:ok, other} -> {:error, "OpenCode made no worktree: #{inspect(other, limit: 3)}"}
      error -> error
    end
  end

  defp q(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
