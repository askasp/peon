defmodule Beamcode.GitFetch do
  @moduledoc """
  Keeps each Code Project's remote refs current, so a new worktree chat starts
  from what's on the remote rather than from wherever the Project's own folder
  was last pulled. Only fetches: the Project's checkout is never touched.

  With `tick: true` (the app's workers) every Code Project is fetched every
  5 minutes; `base/1` fetches again before a new worktree when the
  last fetch is over a minute old.
  """
  use GenServer
  require Logger
  alias Beamcode.{Opencode, Projects}
  alias Beamcode.Projects.Project

  @table :git_fetch
  @every_ms 300_000
  @fresh_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public])
    if opts[:tick], do: Process.send_after(self(), :tick, 30_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 60_000)

    for %Project{kind: "code", directory: dir} = project <- Projects.list_projects(),
        is_binary(dir),
        stale?(project, @every_ms) do
      Task.Supervisor.start_child(Beamcode.TaskSupervisor, fn -> fetch(project) end)
    end

    {:noreply, state}
  rescue
    e ->
      Logger.error("git fetch tick failed: " <> Exception.message(e))
      {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @doc """
  `git fetch origin` in the Project's folder (nothing when it has no origin),
  setting `origin/HEAD` when it's missing. `:ok` or `{:error, output}`.
  """
  def fetch(%Project{} = project) do
    mark(project)

    script =
      "git remote get-url origin >/dev/null 2>&1 || exit 0; " <>
        "GIT_TERMINAL_PROMPT=0 timeout 45 git fetch -q origin || exit 1; " <>
        "git symbolic-ref -q refs/remotes/origin/HEAD >/dev/null || " <>
        "GIT_TERMINAL_PROMPT=0 timeout 15 git remote set-head origin --auto >/dev/null; true"

    case Opencode.run_shell(project.directory, script, 60_000) do
      {:ok, 0, _} ->
        :ok

      other ->
        Logger.info("git fetch #{project.name}: #{inspect(other, limit: 5)}")
        {:error, other}
    end
  end

  @doc """
  The commit a new worktree in `project` starts from, after a fetch when the
  last one is over a minute old: the remote's default branch, or the Project's
  own checkout when that already has everything on it (unpushed work included).
  `nil` without a remote (or when git can't say): OpenCode then uses the checkout.
  """
  def base(%Project{} = project) do
    if stale?(project, @fresh_ms), do: fetch(project)

    script =
      "git rev-parse -q --verify 'refs/remotes/origin/HEAD^{commit}' >/dev/null || exit 0; " <>
        "if git merge-base --is-ancestor origin/HEAD HEAD; then git rev-parse HEAD; " <>
        "else git rev-parse origin/HEAD; fi"

    case Opencode.run_shell(project.directory, script, 15_000) do
      {:ok, 0, out} ->
        if Regex.match?(~r/^[0-9a-f]{40,64}$/, String.trim(out)), do: String.trim(out)

      _ ->
        nil
    end
  end

  defp stale?(%Project{id: id}, ms) do
    case :ets.lookup(@table, id) do
      [{^id, at}] -> System.monotonic_time(:millisecond) - at >= ms
      [] -> true
    end
  end

  # Before the fetch runs, so the ticker and a new chat don't both start one.
  defp mark(%Project{id: id}),
    do: :ets.insert(@table, {id, System.monotonic_time(:millisecond)})
end
