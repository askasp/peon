defmodule Beamcode.SourceSync do
  @moduledoc """
  Pulls a connector source into its table in the Dataset's SQLite file.

  Every synced row carries `_remote_id`, `_source`, `_synced_at` and
  `_pending` (1 while an action on it is posting). Columns the connector
  doesn't know are local: sync never writes them, so notes or your own order
  survive every pull. Remote changes win; actions still posting are applied
  again on top, unless the same field changed remotely in the meantime, which
  fails the action into the Outbox with both values.

  Peon's own tables sit next to the data: `_sources` (what was synced, when,
  the last error), `_fields` (each field's options, so views can draw a board
  in the right order) and `_outbox` (see `Beamcode.Outbox`).
  """
  alias Beamcode.{DataSources, Outbox, ProjectFiles}

  @doc "Syncs source `name` (`s` from `DataSources.read/1`): `:ok` or `{:error, message}`."
  def run(project, name, s) do
    result =
      with {:ok, token} <- DataSources.token(project, s.connector),
           {:ok, pulled} <- s.connector.pull(token, s.config),
           {:ok, pending} <- Outbox.pending(project, s.db, name) do
        ProjectFiles.exec(project, s.db, statements(name, s, pulled, pending))
      end

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)
        ProjectFiles.exec(project, s.db, setup() ++ [record_error(name, s, message)])
        {:error, message}
    end
  end

  @doc "Creates Peon's tables if they're missing."
  def setup do
    [
      {"""
       create table if not exists _sources (name text primary key, connector text, tbl text,
         title text, url text, remote_id text, columns text, rows integer, synced_at text, error text)
       """, []},
      {"""
       create table if not exists _fields (source text, tbl text, col text, label text,
         type text, remote_id text, options text, primary key (source, col))
       """, []},
      {"""
       create table if not exists _outbox (id integer primary key autoincrement, source text,
         tbl text, action text, remote_id text, args text, label text, level text, status text,
         origin text, patch text, before text, error text, created_at text, updated_at text)
       """, []}
    ]
  end

  defp statements(name, s, pulled, pending) do
    now = now()
    t = ident(s.table)
    cols = Enum.map(pulled.columns, &elem(&1, 0))
    all = ["_remote_id", "_source", "_synced_at" | cols]
    marks = Enum.map_join(all, ", ", fn _ -> "?" end)
    updates = Enum.map_join(tl(all), ", ", &"#{ident(&1)} = excluded.#{ident(&1)}")

    create = {
      "create table if not exists #{t} (_remote_id text primary key, _source text, _synced_at text, _pending integer default 0)",
      []
    }

    # A column the table already has fails here; that's fine.
    alters =
      for {col, type} <- pulled.columns,
          do: {"alter table #{t} add column #{ident(col)} #{type}", [], :ignore_error}

    upserts =
      for row <- pulled.rows do
        {"insert into #{t} (#{Enum.map_join(all, ", ", &ident/1)}) values (#{marks}) on conflict(_remote_id) do update set #{updates}",
         [row["_remote_id"], name, now | Enum.map(cols, &row[&1])]}
      end

    deletes =
      if pulled.full do
        ids = Jason.encode!(Enum.map(pulled.rows, & &1["_remote_id"]))

        [
          {"delete from #{t} where _source = ? and _remote_id not in (select value from json_each(?))",
           [name, ids]}
        ]
      else
        []
      end

    by_id = Map.new(pulled.rows, &{&1["_remote_id"], &1})

    setup() ++
      [create] ++
      alters ++
      upserts ++
      deletes ++
      Enum.flat_map(pending, &replay(&1, by_id[&1["remote_id"]], t, s)) ++
      [
        {"delete from _fields where source = ?", [name]}
        | for f <- pulled.fields do
            {"insert into _fields (source, tbl, col, label, type, remote_id, options) values (?, ?, ?, ?, ?, ?, ?)",
             [name, s.table, f.column, f.label, f.type, f.remote_id, Jason.encode!(f.options)]}
          end
      ] ++
      [
        {"""
         insert into _sources (name, connector, tbl, title, url, remote_id, columns, rows, synced_at, error)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, null)
         on conflict(name) do update set connector = excluded.connector, tbl = excluded.tbl,
           title = excluded.title, url = excluded.url, remote_id = excluded.remote_id,
           columns = excluded.columns, rows = excluded.rows, synced_at = excluded.synced_at,
           error = null
         """,
         [
           name,
           s.connector.info().id,
           s.table,
           pulled.title,
           pulled.url,
           pulled.remote_id,
           Jason.encode!(cols),
           length(pulled.rows),
           now
         ]}
      ]
  end

  # An action still posting: its change goes back on top of the fresh row,
  # unless the remote value moved away from what it was when the action was made.
  defp replay(action, remote, t, s) do
    patch = action["patch"] || %{}
    before = action["before"] || %{}

    conflict =
      remote &&
        Enum.find(patch, fn {col, value} ->
          same = &(to_string(&1) == to_string(&2))
          not same.(remote[col], before[col]) and not same.(remote[col], value)
        end)

    cond do
      remote == nil or patch == %{} ->
        []

      conflict ->
        {col, value} = conflict
        service = s.connector.info().name

        [
          {"update _outbox set status = 'failed', error = ?, updated_at = ? where id = ?",
           [
             "#{col} changed on #{service} to #{remote[col] || "empty"} (you set #{value || "empty"})",
             now(),
             action["id"]
           ]}
        ]

      true ->
        sets = Enum.map_join(patch, ", ", fn {col, _} -> "#{ident(col)} = ?" end)

        [
          {"update #{t} set #{sets}, _pending = 1 where _remote_id = ?",
           Enum.map(patch, &elem(&1, 1)) ++ [action["remote_id"]]}
        ]
    end
  end

  defp record_error(name, s, message) do
    {"""
     insert into _sources (name, connector, tbl, error) values (?, ?, ?, ?)
     on conflict(name) do update set error = excluded.error
     """, [name, s.connector.info().id, s.table, message]}
  end

  def now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  def ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
