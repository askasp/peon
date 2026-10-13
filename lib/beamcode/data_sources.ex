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

  Tables filled from the Project's own API calls (`Beamcode.ApiTables`) are
  sources too, read from `.peon/api/*.json` rather than sources.json. GitHub
  Projects and Front stay as connectors only for Datasets that already sync
  them; new ones read from API calls.

  See `Beamcode.SourceSync` and `Beamcode.Outbox`.
  """
  alias Beamcode.{
    ApiTables,
    Connectors,
    Opencode,
    Outbox,
    ProjectFiles,
    Sessions,
    SourceSync,
    Vault
  }

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
      if Enum.any?(sources, fn {_, s} -> s.kind in [:connector, :api] end),
        do: Outbox.status(project, db),
        else: %{}

    for {name, s} <- sources, s.db == db do
      if s.kind in [:connector, :api],
        do: connector_entry(name, s, synced[name]),
        else: script_entry(project, name, s)
    end
  end

  defp connector_entry(name, s, synced) do
    info = info(s)
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
      stale: stale?(synced["synced_at"], s.every_minutes / 60),
      api: if(s.kind == :api, do: s.api.name)
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
            kind when kind in [:connector, :api] ->
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

  ## What a synced source does, whether a connector or an API table

  @doc "Its `Beamcode.SourceConnector.info/0`."
  def info(%{kind: :api} = s), do: ApiTables.info(s)
  def info(s), do: s.connector.info()

  @doc "Pulls it: `{:ok, pull}` (see `Beamcode.SourceConnector`)."
  def pull(project, %{kind: :api} = s), do: ApiTables.pull(project, s)

  def pull(project, s) do
    with {:ok, token} <- token(project, s.connector), do: s.connector.pull(token, s.config)
  end

  def prepare(%{kind: :api} = s, action, args, row, fields),
    do: ApiTables.prepare(s, action, args, row, fields)

  def prepare(s, action, args, row, fields), do: s.connector.prepare(action, args, row, fields)

  def post(project, %{kind: :api} = s, action, args, row, _src, _fields),
    do: ApiTables.post(project, s, action, args, row)

  def post(project, s, action, args, row, src, fields) do
    with {:ok, token} <- token(project, s.connector),
         do: s.connector.post(token, action, args, row, src, fields)
  end

  def undo(%{kind: :api}, _action, _args, _before), do: nil
  def undo(s, action, args, before), do: s.connector.undo(action, args, before)

  @doc "Whether it can sync now: an API table needs its token set in the Project."
  def ready?(project, %{kind: :api, api: c}), do: Connectors.ready?(c, Vault.names(project))
  def ready?(_project, _s), do: true

  @doc """
  A new Dataset's first message in its chat: what it's for, with what the app
  adds (a peon-context block the chat doesn't show) on setting up the APIs it
  names. Returns `{:ok, session_id}`.
  """
  def start_chat(%Project{} = project, user, description) do
    text = """
    #{String.trim(description)}

    ```peon-context
    This Dataset (#{project.name}) was just made for the above. If it names services to read
    from (GitHub Projects, a Front inbox, …), add each under API calls: read its docs and
    write `.peon/api/<service>.json` with the read calls, the tables they fill and the write
    calls as actions (see the sqlite-schema skill). Then ask for each token with the
    `ask_token` tool and wait. Once they're saved: test the read calls, call `source_sync`,
    link rows across APIs that refer to each other, and offer a first view. If it names no
    service, propose the tables to keep. Keep replies short.
    ```
    """

    with {:ok, session} <- Sessions.open(project, user),
         {:ok, _} <- Sessions.send_text(session["id"], text, project.directory) do
      {:ok, session["id"]}
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

  @doc "Sets the level (direct, confirm, off) of one action of a connector source."
  def set_level(%Project{} = project, name, action, level) when level in @levels do
    case read(project)[name] do
      %{kind: :api, api: c} -> ApiTables.set_level(project, c, action, level)
      _ -> set_connector_level(project, name, action, level)
    end
  end

  def set_level(_project, _name, _action, _level),
    do: {:error, "Levels are direct, confirm or off"}

  defp set_connector_level(project, name, action, level) do
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

  @doc "Removes a source from sources.json. Its table stays, as local rows."
  def remove(%Project{} = project, name) do
    json = raw(project)
    if Map.has_key?(json, name), do: write(project, Map.delete(json, name)), else: :ok
  end

  @doc "The synced sources (connectors and API tables): `%{name => source}`."
  def connector_sources(%Project{} = project),
    do:
      for(
        {name, %{kind: k} = s} <- read(project),
        k in [:connector, :api],
        into: %{},
        do: {name, s}
      )

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
    case info(s).actions[action] do
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
    own = for {name, s} <- raw(project), entry = entry(s), into: %{}, do: {name, entry}
    Map.merge(api_tables(project), own)
  end

  # Only a Dataset fills tables from its API calls.
  defp api_tables(%Project{kind: "dataset"} = project), do: ApiTables.sources(project)
  defp api_tables(_project), do: %{}

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
