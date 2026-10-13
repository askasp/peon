defmodule Beamcode.Worktrees do
  @moduledoc """
  The trees a Project's Files tab can show: its own folder ("main") and the git
  worktree of each chat that has one. A tree is named by a `ref`: "main", or
  the chat's session id.

  Only Code Projects give chats worktrees (`Beamcode.Sessions.start/3`).
  """
  alias Beamcode.{Opencode, Sessions}
  alias Beamcode.Projects.Project

  @doc """
  `project` with `directory` set to the tree `ref` names, when `user` may see
  it: "main" (or nil) is the Project's own folder, a chat id that chat's folder.
  `{:ok, project}` or `{:error, :bad_ref}`.
  """
  def at(project, user, ref)

  def at(%Project{} = project, _user, ref) when ref in [nil, "", "main"], do: {:ok, project}

  def at(%Project{id: id} = project, user, ref) when is_binary(ref) do
    case Sessions.fetch_visible(ref, user) do
      {:ok, session, %Project{id: ^id}, _record} ->
        {:ok, %{project | directory: Sessions.session_dir(session, project)}}

      _ ->
        {:error, :bad_ref}
    end
  end

  def at(_project, _user, _ref), do: {:error, :bad_ref}

  @doc "Whether `project` (as returned by `at/3`) is the Project's own folder of a Code Project."
  def code_main?(%Project{kind: "code"} = tree, %Project{} = project),
    do: tree.directory == project.directory

  def code_main?(_tree, _project), do: false

  @doc """
  The chats in `project` with their own worktree that has changes main doesn't
  have: `[%{ref, title, worktree, changed: [path]}]`. A worktree drops out once
  it's merged (or before it has changes); archived chats aren't listed.
  """
  def list(%Project{kind: "code"} = project, user) do
    with {:ok, sessions} <- Sessions.list_visible(project, user) do
      chats =
        for s <- sessions,
            dir = Sessions.session_dir(s, project),
            dir != project.directory,
            do: {s, dir}

      changes = changes(project, chats |> Enum.map(&elem(&1, 1)) |> Enum.uniq())

      {:ok,
       for {s, dir} <- chats,
           paths = Map.get(changes, dir, []),
           paths != [] do
         %{ref: s["id"], title: s["title"], worktree: Path.basename(dir), changed: paths}
       end}
    end
  end

  def list(%Project{}, _user), do: {:ok, []}

  @doc """
  Files each worktree in `dirs` changed since it branched off the commit the
  Project's own folder has checked out, committed or not: `%{dir => [path]}`.
  One shell call in the Project's folder.
  """
  def changes(_project, []), do: %{}

  def changes(%Project{} = project, dirs) do
    git = "git -c core.quotepath=off -C"

    script =
      Enum.map_join(dirs, "\n", fn d ->
        "printf '@@ %s\\n' #{q(d)}; " <>
          "mb=$(#{git} #{q(d)} merge-base HEAD \"$base\" 2>/dev/null) && " <>
          "{ #{git} #{q(d)} diff --name-only \"$mb\"; #{git} #{q(d)} ls-files --others --exclude-standard; }"
      end)

    case Opencode.run_shell(
           project.directory,
           # `true`: a worktree that's gone mustn't fail the others.
           "base=$(git rev-parse HEAD) || exit 1\n" <> script <> "\ntrue",
           30_000
         ) do
      {:ok, 0, out} -> parse(out)
      _ -> %{}
    end
  end

  defp parse(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.chunk_while(
      nil,
      fn
        "@@ " <> dir, nil -> {:cont, {dir, []}}
        "@@ " <> dir, acc -> {:cont, acc, {dir, []}}
        _line, nil -> {:cont, nil}
        line, {dir, paths} -> {:cont, {dir, [line | paths]}}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Map.new(fn {dir, paths} -> {dir, paths |> Enum.reverse() |> Enum.uniq()} end)
  end

  defp q(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
