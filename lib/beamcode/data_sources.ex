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

  A source can instead be a connector (`Beamcode.SourceConnector`), synced by
  Peon itself, with what it may post back and how (`direct`, `confirm`, `off`):

      {
        "github": {"connector": "github.projects", "project": "stadler/12", "table": "items",
                   "actions": {"setField": "direct", "comment": "confirm"}}
      }

  See `Beamcode.SourceSync` and `Beamcode.Outbox`.
  """
  alias Beamcode.{Opencode, Outbox, ProjectFiles, SourceSync, Vault}
  alias Beamcode.Projects.Project
  alias Beamcode.SourceConnectors.{Front, GithubProjects}

  @connectors [GithubProjects, Front]
  @levels ~w(direct confirm off)
  @default_minutes 5

  @file_name "sources.json"
  @run_ms 600_000
  @runners %{".py" => "python3", ".sh" => "sh", ".js" => "node"}

  @doc """
  The sources writing into `db`: `[%{name, table, every_hours, fetched_at, stale}]`,
  `[]` without a (valid) sources.json.
  """
  def list(%Project{} = project, db \\ "data.sqlite") do
    sources = read(project)

    synced =
      if Enum.any?(sources, fn {_, s} -> s.kind == :connector end),
        do: Outbox.status(project, db),
        else: %{}

    for {name, s} <- sources, s.db == db do
      if s.kind == :connector,
        do: connector_entry(name, s, synced[name]),
        else: script_entry(project, name, s)
    end
  end

  defp connector_entry(name, s, synced) do
    info = s.connector.info()
    synced = synced || %{}

    %{
      name: name,
      table: s.table,
      connector: info.id,
      connector_name: info.name,
      short: info.short,
      title: synced["title"] || s.config[info.config_key],
      url: synced["url"],
      every_hours: s.every_minutes / 60,
      fetched_at: synced["synced_at"],
      error: synced["error"],
      rows: synced["rows"],
      waiting: synced["waiting"] || 0,
      posting: synced["posting"] || 0,
      failed: synced["failed"] || 0,
      stale: stale?(synced["synced_at"], s.every_minutes / 60)
    }
  end

  defp script_entry(project, name, s) do
    fetched_at = fetched_at(project, s)

    %{
      name: name,
      table: s.table,
      every_hours: s.every_hours,
      fetched_at: fetched_at,
      stale: stale?(fetched_at, s.every_hours)
    }
  end

  @doc """
  Runs a source's script in the folder, or syncs a connector source (one
  refresh per folder at a time): `:ok`, or `{:error, message}` with the
  script's last line of output.
  """
  def refresh(%Project{} = project, name) do
    with {:ok, s} <- fetch(project, name) do
      lock = {{__MODULE__, project.directory}, self()}

      if :global.set_lock(lock, [node()], 0) do
        try do
          case s.kind do
            :connector ->
              SourceSync.run(project, name, s)

            :script ->
              with {:ok, runner} <- runner(s.script), do: run(project, runner, s.script)
          end
        after
          :global.del_lock(lock, [node()])
        end
      else
        {:error, "Another source in this folder is refreshing"}
      end
    end
  end

  ## Connectors

  def connectors, do: @connectors

  def connector(id), do: Enum.find(@connectors, &(&1.info().id == id))

  @doc """
  A connector's token from the Project's vault: `{:ok, token}` or an error
  saying how to connect. Each Project connects on its own.
  """
  def token(%Project{} = project, mod) do
    info = mod.info()

    case Vault.fetch(project, info.secret) do
      {:ok, token} ->
        {:ok, token}

      _ ->
        {:error,
         "#{info.name} isn't connected in this Project. Connect it in Settings → Source (#{info.secret})."}
    end
  end

  @doc """
  Each connector, whether the Project has a token for it, and its actions with
  their default levels. Without a Project (one being made) nothing is connected.
  """
  def connector_list(project \\ nil) do
    secrets = if project, do: Vault.names(project), else: MapSet.new()

    for mod <- @connectors do
      info = mod.info()

      %{
        id: info.id,
        name: info.name,
        short: info.short,
        secret: info.secret,
        connected: MapSet.member?(secrets, info.secret),
        actions:
          for(
            {k, a} <- Enum.sort(info.actions),
            do: %{name: k, label: a.label, default: a.default}
          )
      }
    end
  end

  @doc "Saves a connector's token in the Project after checking it with the service: `{:ok, account}`."
  def connect(%Project{} = project, id, token, user) when is_binary(token) do
    mod = connector(id)

    with %{} = info <- mod && mod.info(),
         token = String.trim(token),
         {:ok, account} <- mod.account(token),
         {:ok, _} <- Vault.put(project, info.secret, token, user) do
      {:ok, account}
    else
      nil -> {:error, "No connector #{id}"}
      error -> error
    end
  end

  @doc """
  What a connector can sync (projects, inboxes), and who it's connected as:
  with the Project's token, or with `token` itself for a Project not made yet.
  """
  def choices(%Project{} = project, id) do
    with mod when not is_nil(mod) <- connector(id),
         {:ok, token} <- token(project, mod) do
      list_choices(mod, token)
    else
      nil -> {:error, "No connector #{id}"}
      error -> error
    end
  end

  def choices(id, token) when is_binary(id) and is_binary(token) do
    case connector(id) do
      nil -> {:error, "No connector #{id}"}
      mod -> list_choices(mod, String.trim(token))
    end
  end

  defp list_choices(mod, token) do
    with {:ok, account} <- mod.account(token),
         {:ok, choices} <- mod.choices(token) do
      {:ok, %{account: account, choices: choices}}
    end
  end

  @doc """
  Adds a connector source to sources.json with the connector's default levels:
  `{:ok, name}`. `choice` is what to sync (a project, an inbox).
  """
  def add(%Project{} = project, id, choice) do
    with mod when not is_nil(mod) <- connector(id) do
      info = mod.info()
      json = raw(project)
      base = info.id |> String.split(".") |> hd()
      name = Enum.find([base | for(n <- 2..20, do: "#{base}#{n}")], &(not Map.has_key?(json, &1)))
      tables = for {_, %{"table" => t}} <- json, do: t

      table =
        Enum.find([info.table | for(n <- 2..20, do: "#{info.table}#{n}")], &(&1 not in tables))

      entry = %{
        "connector" => info.id,
        info.config_key => to_string(choice || ""),
        "table" => table,
        "every_minutes" => @default_minutes,
        "actions" => Map.new(info.actions, fn {k, a} -> {k, a.default} end)
      }

      with :ok <- write(project, Map.put(json, name, entry)), do: {:ok, name}
    else
      nil -> {:error, "No connector #{id}"}
    end
  end

  @doc "Sets the level (direct, confirm, off) of one action of a connector source."
  def set_level(%Project{} = project, name, action, level) when level in @levels do
    json = raw(project)

    with %{"connector" => id} = entry <- json[name],
         mod when not is_nil(mod) <- connector(id),
         true <- Map.has_key?(mod.info().actions, action) do
      entry = Map.update(entry, "actions", %{action => level}, &Map.put(&1, action, level))
      write(project, Map.put(json, name, entry))
    else
      _ -> {:error, "No action #{action} on #{name}"}
    end
  end

  def set_level(_project, _name, _action, _level),
    do: {:error, "Levels are direct, confirm or off"}

  @doc "Removes a source from sources.json. Its table stays, as local rows."
  def remove(%Project{} = project, name) do
    json = raw(project)
    if Map.has_key?(json, name), do: write(project, Map.delete(json, name)), else: :ok
  end

  @doc "The connector sources: `%{name => source}`."
  def connector_sources(%Project{} = project),
    do: for({name, %{kind: :connector} = s} <- read(project), into: %{}, do: {name, s})

  @doc "Columns added to a synced table here (notes, your own order): sync never writes them."
  def local_columns(%Project{} = project, name, s) do
    q = fn sql -> ProjectFiles.query(project, s.db, sql) end
    esc = &String.replace(&1, "'", "''")

    with {:ok, cols} <- q.("select name from pragma_table_info('#{esc.(s.table)}')"),
         {:ok, [%{"columns" => synced}]} <-
           q.("select columns from _sources where name = '#{esc.(name)}'"),
         {:ok, synced} <- Jason.decode(synced || "[]") do
      for %{"name" => c} <- cols, not String.starts_with?(c, "_"), c not in synced, do: c
    else
      _ -> []
    end
  end

  @doc "The level of an action on a source: direct, confirm or off."
  def level(s, action) do
    case s.connector.info().actions[action] do
      nil -> nil
      a -> s.actions[action] || a.default
    end
  end

  defp raw(project) do
    with {:ok, body} <- Opencode.read_file(project.directory, @file_name),
         {:ok, %{} = json} <- Jason.decode(body) do
      json
    else
      _ -> %{}
    end
  end

  defp write(project, json),
    do: ProjectFiles.write(project, @file_name, Jason.encode!(json, pretty: true) <> "\n")

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

  @doc false
  def read(project) do
    for {name, s} <- raw(project), entry = entry(s), into: %{}, do: {name, entry}
  end

  defp entry(%{"script" => script, "table" => table} = s) when is_binary(table) do
    with {:ok, script} <- ProjectFiles.clean_path(script),
         true <- String.starts_with?(script, "sources/"),
         {:ok, db} <- ProjectFiles.clean_path(s["db"] || "data.sqlite") do
      %{kind: :script, script: script, table: table, db: db, every_hours: hours(s["every_hours"])}
    else
      _ -> nil
    end
  end

  defp entry(%{"connector" => id, "table" => table} = s) when is_binary(table) do
    with mod when not is_nil(mod) <- connector(id),
         true <- table =~ ~r/^[A-Za-z][A-Za-z0-9_]*$/,
         {:ok, db} <- ProjectFiles.clean_path(s["db"] || "data.sqlite") do
      %{
        kind: :connector,
        connector: mod,
        table: table,
        db: db,
        config: Map.drop(s, ~w(connector table db actions every_minutes)),
        actions: for({k, v} <- s["actions"] || %{}, v in @levels, into: %{}, do: {k, v}),
        every_minutes: minutes(s["every_minutes"])
      }
    else
      _ -> nil
    end
  end

  defp entry(_), do: nil

  defp minutes(m) when is_number(m) and m >= 1, do: m
  defp minutes(_), do: @default_minutes

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
