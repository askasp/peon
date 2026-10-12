defmodule Beamcode.ProjectFiles do
  @moduledoc """
  A project's files, for the Files tab and its views. Paths are relative to the
  project folder.

  OpenCode's fs API lists any folder it's given (`/etc` included), so every path
  is cleaned here first: absolute paths, `..` and NUL bytes are refused.
  """
  alias Beamcode.Opencode
  alias Beamcode.Projects.Project

  # Files bigger than this aren't opened (views, raw downloads).
  @max_bytes 10_000_000

  @doc "A path made safe to use inside the folder (`\".\"` for the folder itself), or `:error`."
  def clean_path(path) when is_binary(path) do
    parts = path |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))

    cond do
      String.contains?(path, ["\0", "\\"]) -> :error
      String.starts_with?(path, ["/", "~"]) -> :error
      ".." in parts -> :error
      parts == [] -> {:ok, "."}
      true -> {:ok, Enum.join(parts, "/")}
    end
  end

  def clean_path(_), do: :error

  @doc """
  The entries in a subfolder: `[%{name, path, type}]` with `type` "directory" or
  "file", subfolders first. Dotfiles are left out.
  """
  def list(%Project{} = project, path) do
    with {:ok, path} <- clean(path),
         {:ok, entries} <- Opencode.list_dir(project.directory, path) do
      {:ok,
       for(
         %{"path" => p, "type" => type} <- entries,
         {:ok, p} <- [clean_path(p)],
         p != ".",
         name = Path.basename(p),
         not String.starts_with?(name, "."),
         do: %{name: name, path: p, type: type}
       )
       |> Enum.sort_by(&{&1.type != "directory", String.downcase(&1.name)})}
    end
  end

  @doc """
  A file's bytes: `{:ok, binary}`, or `{:error, :bad_path | :enoent | :too_big | reason}`.
  A `.env` (a dataset source's keys) is never read out: only scripts in the folder use it.
  """
  def read(%Project{} = project, path, max_bytes \\ @max_bytes) do
    with {:ok, path} <- clean(path),
         :ok <- if(Path.basename(path) == ".env", do: {:error, :enoent}, else: :ok),
         {:ok, body} <- Opencode.read_file(project.directory, path) do
      if byte_size(body) > max_bytes, do: {:error, :too_big}, else: {:ok, body}
    end
  end

  @doc "Writes a text file in the folder (the Document view's Save)."
  def write(%Project{} = project, path, content) when is_binary(content) do
    with {:ok, path} <- clean(path),
         {:ok, _} <- Opencode.write_file(project.directory, path, content) do
      :ok
    end
  end

  @doc """
  A SQLite file's tables and one table's rows, read with the `sqlite3` command
  on the OpenCode server: `{:ok, %{tables: [%{name, rows}], table, columns, rows}}`.
  At most `limit` rows come back.
  """
  def table(%Project{} = project, path, table \\ nil, limit \\ 500) do
    with {:ok, path} <- clean(path),
         {:ok, names} <-
           sql(project, path, "select name from sqlite_master where type='table' order by name") do
      names = for %{"name" => n} <- names, do: n
      # Peon's own tables (_outbox…) and SQLite's open only when asked for.
      table =
        if table in names,
          do: table,
          else:
            Enum.find(names, &(not String.starts_with?(&1, ["_", "sqlite_"]))) ||
              List.first(names)

      counts =
        for n <- names do
          case sql(project, path, "select count(*) as n from #{ident(n)}") do
            {:ok, [%{"n" => c}]} -> %{name: n, rows: c}
            _ -> %{name: n, rows: nil}
          end
        end

      with {:ok, rows} <-
             (table && sql(project, path, "select * from #{ident(table)} limit #{limit}")) ||
               {:ok, []},
           {:ok, cols} <-
             (table &&
                sql(
                  project,
                  path,
                  "select name from pragma_table_info('#{String.replace(table, "'", "''")}')"
                )) || {:ok, []} do
        {:ok, %{tables: counts, table: table, columns: Enum.map(cols, & &1["name"]), rows: rows}}
      end
    end
  end

  @doc """
  A read-only query on a SQLite file in the folder, for the apps agents write
  over a dataset (`peon.query` in their pages): `{:ok, rows}`, rows as maps.
  """
  def query(%Project{} = project, path, query) when is_binary(query) do
    with {:ok, path} <- clean(path) do
      if String.starts_with?(String.trim_leading(query), "."),
        do: {:error, "Only SQL, no dot commands"},
        else: sql(project, path, query)
    end
  end

  @exec_py ~S"""
  import sqlite3, json, sys
  job = json.load(open(sys.argv[1]))
  c = sqlite3.connect(job["db"], timeout=30)
  c.row_factory = sqlite3.Row
  rows = []
  with c:
      for st in job["statements"]:
          try:
              cur = c.execute(st[0], st[1])
          except sqlite3.OperationalError:
              if len(st) > 2: continue
              raise
          rows = [dict(r) for r in cur.fetchall()] if cur.description else []
  print(json.dumps(rows, default=str))
  """

  @doc """
  Runs `statements` (`[{sql, params}]`, params a list; `{sql, params,
  :ignore_error}` for one that may fail, like adding a column twice) in one transaction on a
  SQLite file in the folder, with Python's sqlite3 module on the OpenCode server.
  For Peon's own writes (dataset sources, the Outbox); the SQL is never user
  input. The statements go through a file in `.peon/`, so a big sync isn't
  limited by the command line. Returns `{:ok, rows}`: the rows of the last
  statement, as maps.
  """
  def exec(%Project{} = project, path, statements) when is_list(statements) do
    file = ".peon/sql-#{System.unique_integer([:positive])}.json"

    with {:ok, path} <- clean(path),
         true <- path != "." || {:error, :bad_path},
         {:ok, _} <- Opencode.write_file(project.directory, file, exec_payload(path, statements)) do
      cmd = "python3 -c #{q(@exec_py)} #{q(file)}; s=$?; rm -f #{q(file)}; exit $s"

      case Opencode.run_shell(project.directory, cmd, 120_000) do
        {:ok, 0, out} -> Jason.decode(out |> String.split("\n", trim: true) |> List.last("[]"))
        {:ok, 127, _} -> {:error, "python3 is not installed on the server"}
        {:ok, _, out} -> {:error, out |> String.trim() |> String.split("\n") |> List.last()}
        error -> error
      end
    end
  end

  defp exec_payload(path, statements) do
    Jason.encode!(%{
      db: path,
      statements:
        for st <- statements do
          case st do
            {sql, params} -> [sql, params]
            {sql, params, :ignore_error} -> [sql, params, true]
          end
        end
    })
  end

  defp ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  # Read-only, rows as JSON maps: the sqlite3 command if the server has it, else
  # Python's sqlite3 module. Both refuse ATTACH, so a query can't reach other
  # files (-safe also turns off .shell and extensions).
  @py ~S"""
  import sqlite3, json, sys
  c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
  c.set_authorizer(lambda action, *_: 1 if action == 24 else 0)
  c.row_factory = sqlite3.Row
  print(json.dumps([dict(r) for r in c.execute(sys.argv[2])], default=str))
  """

  defp sql(project, path, query) do
    cmd =
      "if command -v sqlite3 >/dev/null; then sqlite3 -readonly -safe -json #{q(path)} #{q(query)}; " <>
        "else python3 -c #{q(@py)} #{q(path)} #{q(query)}; fi"

    case Opencode.run_shell(project.directory, cmd, 30_000) do
      {:ok, 0, out} -> if String.trim(out) == "", do: {:ok, []}, else: Jason.decode(out)
      {:ok, 127, _} -> {:error, "Neither sqlite3 nor python3 is installed on the server"}
      {:ok, _, out} -> {:error, out |> String.trim() |> String.split("\n") |> List.last()}
      error -> error
    end
  end

  defp q(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  @doc "Whether `body` can be shown as text."
  def text?(body), do: String.valid?(body) and not String.contains?(body, "\0")

  def content_type(path), do: MIME.from_path(path)

  defp clean(path) do
    case clean_path(path) do
      {:ok, p} -> {:ok, p}
      :error -> {:error, :bad_path}
    end
  end
end
