defmodule Beamcode.DataSources do
  @moduledoc """
  A dataset's sources: scripts that fetch data from somewhere else (an API, a
  feed) into a table, listed in the folder's `sources.json`:

      {
        "strava": {"script": "sources/strava.py", "table": "strava_runs", "every_hours": 6}
      }

  The agent writes the script once from a chat; refreshing runs it again without
  the agent. A script reads its keys from the environment (the folder's `.env` is
  loaded first) and upserts into its table with a `fetched_at` column (ISO UTC),
  so how old the data is comes from the data itself, whoever ran the script.
  `"db"` names another SQLite file than data.sqlite.
  """
  alias Beamcode.{Opencode, ProjectFiles}
  alias Beamcode.Projects.Project

  @file_name "sources.json"
  @run_ms 600_000
  @runners %{".py" => "python3", ".sh" => "sh", ".js" => "node"}

  @doc """
  The sources writing into `db`: `[%{name, table, every_hours, fetched_at, stale}]`,
  `[]` without a (valid) sources.json.
  """
  def list(%Project{} = project, db \\ "data.sqlite") do
    for {name, s} <- read(project), s.db == db do
      fetched_at = fetched_at(project, s)

      %{
        name: name,
        table: s.table,
        every_hours: s.every_hours,
        fetched_at: fetched_at,
        stale: stale?(fetched_at, s.every_hours)
      }
    end
  end

  @doc """
  Runs a source's script in the folder (one refresh per folder at a time):
  `:ok`, or `{:error, message}` with the script's last line of output.
  """
  def refresh(%Project{} = project, name) do
    with {:ok, s} <- fetch(project, name),
         {:ok, runner} <- runner(s.script) do
      lock = {{__MODULE__, project.directory}, self()}

      if :global.set_lock(lock, [node()], 0) do
        try do
          run(project, runner, s.script)
        after
          :global.del_lock(lock, [node()])
        end
      else
        {:error, "Another source in this folder is refreshing"}
      end
    end
  end

  defp run(project, runner, script) do
    cmd = "set -a; [ -f .env ] && . ./.env; set +a; #{runner} #{q(script)}"

    case Opencode.run_shell(project.directory, cmd, @run_ms) do
      {:ok, 0, _} ->
        :ok

      {:ok, 127, _} ->
        {:error, "#{runner} is not installed on the server"}

      {:ok, _, out} ->
        {:error, last_line(out) || "#{script} failed"}

      {:error, :timeout} ->
        {:error, "#{script} ran for more than #{div(@run_ms, 60_000)} minutes"}

      error ->
        error
    end
  end

  defp fetch(project, name) do
    case read(project)[name] do
      nil -> {:error, "No source #{name} in #{@file_name}"}
      s -> {:ok, s}
    end
  end

  defp runner(script) do
    case @runners[Path.extname(script)] do
      nil -> {:error, "Sources run .py, .sh or .js scripts"}
      runner -> {:ok, runner}
    end
  end

  defp read(project) do
    with {:ok, body} <- Opencode.read_file(project.directory, @file_name),
         {:ok, %{} = json} <- Jason.decode(body) do
      for {name, %{"script" => script, "table" => table} = s} <- json,
          is_binary(table),
          {:ok, script} <- [ProjectFiles.clean_path(script)],
          String.starts_with?(script, "sources/"),
          {:ok, db} <- [ProjectFiles.clean_path(s["db"] || "data.sqlite")],
          into: %{},
          do:
            {name, %{script: script, table: table, db: db, every_hours: hours(s["every_hours"])}}
    else
      _ -> %{}
    end
  end

  defp hours(h) when is_number(h) and h > 0, do: h
  defp hours(_), do: nil

  defp fetched_at(project, s) do
    table = ~s("#{String.replace(s.table, ~s("), ~s(""))}")

    case ProjectFiles.query(project, s.db, "select max(fetched_at) as at from #{table}") do
      {:ok, [%{"at" => at}]} when is_binary(at) -> at
      _ -> nil
    end
  end

  defp stale?(nil, _), do: true
  defp stale?(_, nil), do: false

  defp stale?(at, hours) do
    case DateTime.from_iso8601(at) do
      {:ok, t, _} -> DateTime.diff(DateTime.utc_now(), t) > hours * 3600
      _ -> true
    end
  end

  defp last_line(out) do
    case out |> String.trim() |> String.split("\n") |> List.last() do
      "" -> nil
      line -> line
    end
  end

  defp q(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
