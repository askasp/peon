defmodule Beamcode.Outbox do
  @moduledoc """
  Every change a Dataset posts back to a source's service goes through here:
  from a view (`peon.act`), from the agent in the chat or from a scheduled run.

  The action's level in sources.json decides what happens:

    * `direct`: the change is applied to the local row at once (the row is
      marked `_pending`) and posted in the background. Undo posts the reverse.
    * `confirm`: the action waits in the Outbox until someone presses Post
      (they can edit it first) or Skip.
    * `off`: refused.

  A failed post puts the local row back as it was and stays in the Outbox with
  Retry. Entries live in the `_outbox` table next to the data.
  """
  require Logger
  alias Beamcode.{DataSources, ProjectFiles, SourceSync}
  alias Beamcode.Projects.Project

  @doc """
  Queues an action on row `remote_id` (nil for one that makes a row, like
  create) of source `name` (nil when the Folder has one): `{:ok, entry}`.
  """
  def act(%Project{} = project, name, action, remote_id, args, origin, opts \\ []) do
    args = if is_map(args), do: args, else: %{}

    with {:ok, name, s} <- source(project, name),
         {:ok, level} <- level(s, action, opts[:level]),
         {:ok, row} <- row(project, s, action, remote_id),
         {:ok, fields} <- fields(project, s.db, name),
         {:ok, patch, label} <- s.connector.prepare(action, args, row, fields) do
      status = if level == "direct", do: "posting", else: "waiting"
      before = Map.new(patch, fn {col, _} -> {col, row[col]} end)
      now = SourceSync.now()

      insert =
        {"""
         insert into _outbox (source, tbl, action, remote_id, args, label, level, status, origin,
           patch, before, created_at, updated_at)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         """,
         [
           name,
           s.table,
           action,
           row && row["_remote_id"],
           Jason.encode!(args),
           label,
           level,
           status,
           to_string(origin),
           Jason.encode!(patch),
           Jason.encode!(before),
           now,
           now
         ]}

      apply = if level == "direct", do: apply_patch(s.table, remote_id, patch), else: []

      with {:ok, [entry]} <-
             ProjectFiles.exec(
               project,
               s.db,
               SourceSync.setup() ++
                 [insert | apply] ++
                 [{"select * from _outbox where id = last_insert_rowid()", []}]
             ) do
        entry = decode(entry)
        if level == "direct", do: post_later(project, s.db, entry["id"])
        {:ok, entry}
      end
    end
  end

  @doc "Posts a waiting action, with `args` changed if given (Edit, then Post)."
  def approve(%Project{} = project, db, id, args \\ nil) do
    with {:ok, %{"status" => "waiting"} = e} <- entry(project, db, id) do
      requeue(project, db, e, args || e["args"])
    else
      {:ok, _} -> {:error, "Only waiting actions can be posted"}
      error -> error
    end
  end

  @doc "Posts a failed action again, against the row as it is now."
  def retry(%Project{} = project, db, id) do
    with {:ok, %{"status" => "failed"} = e} <- entry(project, db, id) do
      requeue(project, db, e, e["args"])
    else
      {:ok, _} -> {:error, "Only failed actions can be retried"}
      error -> error
    end
  end

  defp requeue(project, db, e, args) do
    with {:ok, _name, s} <- source(project, e["source"]),
         {:ok, row} <- row(project, s, e["action"], e["remote_id"]),
         {:ok, fields} <- fields(project, db, e["source"]),
         {:ok, patch, label} <- s.connector.prepare(e["action"], args, row, fields),
         {:ok, _} <-
           ProjectFiles.exec(
             project,
             db,
             [
               {"""
                update _outbox set status = 'posting', args = ?, label = ?, patch = ?, before = ?,
                  error = null, updated_at = ? where id = ?
                """,
                [
                  Jason.encode!(args),
                  label,
                  Jason.encode!(patch),
                  Jason.encode!(Map.new(patch, fn {col, _} -> {col, row[col]} end)),
                  SourceSync.now(),
                  e["id"]
                ]}
               | apply_patch(s.table, e["remote_id"], patch)
             ]
           ) do
      post_later(project, db, e["id"])
      :ok
    end
  end

  @doc "Drops a waiting action without posting it."
  def skip(%Project{} = project, db, id), do: settle(project, db, id, "waiting", "skipped")

  @doc "Posts the reverse of a posted action (Status back to what it was, reopen…)."
  def undo(%Project{} = project, db, id) do
    with {:ok, %{"status" => "posted"} = e} <- entry(project, db, id),
         {:ok, _name, s} <- source(project, e["source"]),
         {back, args} <-
           s.connector.undo(e["action"], e["args"], e["before"]) ||
             {:error, "This can't be undone"},
         {:ok, entry} <-
           act(project, e["source"], back, e["remote_id"], args, "undo", level: "direct"),
         :ok <- settle(project, db, id, "posted", "undone") do
      {:ok, entry}
    else
      {:ok, _} -> {:error, "Only posted actions can be undone"}
      error -> error
    end
  end

  @doc "The latest entries, newest first."
  def list(%Project{} = project, db \\ "data.sqlite", limit \\ 50) do
    case ProjectFiles.query(project, db, "select * from _outbox order by id desc limit #{limit}") do
      {:ok, rows} -> Enum.map(rows, &decode/1)
      _ -> []
    end
  end

  @doc "Actions still posting for a source (sync applies them again on top)."
  def pending(%Project{} = project, db, name) do
    q =
      "select * from _outbox where status = 'posting' and source = '#{String.replace(name, "'", "''")}'"

    case ProjectFiles.query(project, db, q) do
      {:ok, rows} -> {:ok, Enum.map(rows, &decode/1)}
      # No _outbox yet (first sync), or no data.sqlite.
      {:error, _} -> {:ok, []}
    end
  end

  @doc """
  Each synced source's last sync and Outbox counts: `%{name => %{"title",
  "synced_at", "error", "rows", "waiting", "posting", "failed"}}`.
  """
  def status(%Project{} = project, db) do
    q = """
    select s.*,
      (select count(*) from _outbox o where o.source = s.name and o.status = 'waiting') as waiting,
      (select count(*) from _outbox o where o.source = s.name and o.status = 'posting') as posting,
      (select count(*) from _outbox o where o.source = s.name and o.status = 'failed') as failed
    from _sources s
    """

    case ProjectFiles.query(project, db, q) do
      {:ok, rows} -> Map.new(rows, &{&1["name"], &1})
      _ -> %{}
    end
  end

  ## Posting

  defp post_later(project, db, id) do
    if Application.get_env(:beamcode, :outbox_inline, false) do
      post(project, db, id)
    else
      Task.Supervisor.start_child(Beamcode.TaskSupervisor, fn -> post(project, db, id) end)
    end
  end

  @doc false
  def post(project, db, id) do
    with {:ok, %{"status" => "posting"} = e} <- entry(project, db, id) do
      result =
        with {:ok, _name, s} <- source(project, e["source"]),
             {:ok, token} <- DataSources.token(s.connector),
             {:ok, row} <- row(project, s, e["action"], e["remote_id"]),
             {:ok, fields} <- fields(project, db, e["source"]),
             {:ok, src} <- synced_source(project, db, e["source"]) do
          s.connector.post(token, e["action"], e["args"], row, src, fields)
        end

      case result do
        :ok ->
          ProjectFiles.exec(project, db, [
            {"update _outbox set status = 'posted', error = null, updated_at = ? where id = ?",
             [SourceSync.now(), id]}
            | unmark(e["tbl"], e["remote_id"])
          ])

          if e["remote_id"] == nil, do: refresh_soon(project, e["source"])
          :ok

        {:error, message} ->
          fail(project, db, e, message)
      end
    else
      _ -> :ok
    end
  end

  # A new row (create): services list it a few seconds after they accept it.
  defp refresh_soon(project, name) do
    unless Application.get_env(:beamcode, :outbox_inline, false) do
      Task.Supervisor.start_child(Beamcode.TaskSupervisor, fn ->
        Process.sleep(5_000)
        DataSources.refresh(project, name)
      end)
    end
  end

  # The post didn't go through: the row goes back to what it was.
  defp fail(project, db, e, message) do
    message = if is_binary(message), do: message, else: inspect(message)
    Logger.info("outbox #{e["source"]} #{e["action"]} failed: #{message}")

    ProjectFiles.exec(
      project,
      db,
      [
        {"update _outbox set status = 'failed', error = ?, updated_at = ? where id = ?",
         [message, SourceSync.now(), e["id"]]}
      ] ++
        apply_patch(e["tbl"], e["remote_id"], e["before"] || %{}) ++
        unmark(e["tbl"], e["remote_id"])
    )

    {:error, message}
  end

  ## Helpers

  defp source(project, name) do
    sources = DataSources.connector_sources(project)

    case {name, Map.to_list(sources)} do
      {nil, [{name, s}]} -> {:ok, name, s}
      {nil, []} -> {:error, "This Folder has no synced source"}
      {nil, _} -> {:error, "Say which source: #{sources |> Map.keys() |> Enum.join(", ")}"}
      {name, _} -> if s = sources[name], do: {:ok, name, s}, else: {:error, "No source #{name}"}
    end
  end

  defp level(s, action, forced) do
    info = s.connector.info()

    case forced || DataSources.level(s, action) do
      nil ->
        {:error,
         "#{info.name} has no action #{action}. Actions: #{info.actions |> Map.keys() |> Enum.join(", ")}"}

      "off" ->
        {:error, "#{info.actions[action].label} is off for this Folder (Settings → Source)"}

      level ->
        {:ok, level}
    end
  end

  defp row(project, s, action, remote_id) do
    needs_row = get_in(s.connector.info().actions, [action, :needs_row]) != false

    cond do
      not needs_row and remote_id in [nil, ""] ->
        {:ok, nil}

      not is_binary(remote_id) or remote_id == "" ->
        {:error, "#{action} needs a row (its _remote_id)"}

      true ->
        q =
          "select * from #{SourceSync.ident(s.table)} where _remote_id = '#{String.replace(remote_id, "'", "''")}'"

        case ProjectFiles.query(project, s.db, q) do
          {:ok, [row]} -> {:ok, row}
          {:ok, []} -> {:error, "No row #{remote_id} in #{s.table}"}
          error -> error
        end
    end
  end

  defp fields(project, db, name) do
    q =
      "select col, label, type, remote_id, options from _fields where source = '#{String.replace(name, "'", "''")}'"

    case ProjectFiles.query(project, db, q) do
      {:ok, rows} ->
        {:ok,
         for r <- rows do
           r
           |> Map.put("column", r["col"])
           |> Map.put("options", decode_json(r["options"]) || [])
         end}

      {:error, _} ->
        {:ok, []}
    end
  end

  defp synced_source(project, db, name) do
    case ProjectFiles.query(
           project,
           db,
           "select * from _sources where name = '#{String.replace(name, "'", "''")}'"
         ) do
      {:ok, [src]} -> {:ok, src}
      _ -> {:error, "#{name} hasn't synced yet"}
    end
  end

  defp entry(project, db, id) when is_integer(id) do
    case ProjectFiles.query(project, db, "select * from _outbox where id = #{id}") do
      {:ok, [e]} -> {:ok, decode(e)}
      {:ok, []} -> {:error, "No Outbox entry #{id}"}
      error -> error
    end
  end

  defp entry(_project, _db, _id), do: {:error, "No Outbox entry"}

  defp settle(project, db, id, from, to) do
    with {:ok, %{"status" => ^from}} <- entry(project, db, id),
         {:ok, _} <-
           ProjectFiles.exec(project, db, [
             {"update _outbox set status = ?, updated_at = ? where id = ?",
              [to, SourceSync.now(), id]}
           ]) do
      :ok
    else
      {:ok, _} -> {:error, "This action is no longer #{from}"}
      error -> error
    end
  end

  defp apply_patch(_table, nil, _patch), do: []
  defp apply_patch(_table, _id, patch) when patch == %{}, do: []

  defp apply_patch(table, remote_id, patch) do
    sets = Enum.map_join(patch, ", ", fn {col, _} -> "#{SourceSync.ident(col)} = ?" end)

    [
      {"update #{SourceSync.ident(table)} set #{sets}, _pending = 1 where _remote_id = ?",
       Enum.map(patch, &elem(&1, 1)) ++ [remote_id]}
    ]
  end

  defp unmark(_table, nil), do: []

  defp unmark(table, remote_id) do
    [
      {"""
       update #{SourceSync.ident(table)} set _pending = 0 where _remote_id = ?
         and not exists (select 1 from _outbox where remote_id = ? and status = 'posting')
       """, [remote_id, remote_id]}
    ]
  end

  defp decode(e) do
    e
    |> Map.update("args", %{}, &(decode_json(&1) || %{}))
    |> Map.update("patch", %{}, &(decode_json(&1) || %{}))
    |> Map.update("before", %{}, &(decode_json(&1) || %{}))
  end

  defp decode_json(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  defp decode_json(v), do: v
end
