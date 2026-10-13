defmodule Beamcode.ApiTables do
  @moduledoc """
  A Dataset's tables filled from its own API calls (`.peon/api/<service>.json`),
  with nothing in Peon's code about the service. A file's `"tables"` says which
  read call fills which table and where each column is in a row:

      "tables": {
        "conversations": {
          "call": "list_conversations",
          "args": {"inbox": "inb_1", "query": {"limit": 100}},
          "rows": "_results",
          "id": "id",
          "columns": {
            "subject": "subject",
            "assignee": "assignee.email",
            "tags": "tags[].name",
            "status": {"path": "fieldValues.nodes[field.name=Status].name", "options": ["Todo", "Done"]},
            "created_at": {"path": "created_at", "type": "time"}
          },
          "next": "_pagination.next",
          "pages": 3,
          "every_minutes": 5
        }
      }

  Paths are dot-separated keys; `[]` takes every item of a list, `[n]` one,
  and `[key=value]` the first whose `key` is `value`. Paging follows `next`
  (a URL in the response) or `cursor` (`{"from": path, "to": name}`: the value
  at `from` goes back as variable or query parameter `to`).

  Each such table is a source like a connector's (see `Beamcode.SourceSync`):
  the same local columns, `_fields`, Outbox and views. Its actions are the
  file's write calls; a call's permission is the action's level (allow is
  direct, ask is confirm, deny is off). A row's columns and `id` (its
  `_remote_id`) fill an action's path and body.
  """
  alias Beamcode.Connectors
  alias Beamcode.Projects.Project

  @default_minutes 5
  @default_pages 5
  @max_pages 50
  @types ~w(text integer real time json)

  @doc "Permission (in the API file) ↔ level (Outbox)."
  def level("allow"), do: "direct"
  def level("ask"), do: "confirm"
  def level(_deny), do: "off"

  def permission("direct"), do: "allow"
  def permission("confirm"), do: "ask"
  def permission("off"), do: "deny"

  @doc """
  The Project's API tables as sources: `%{table => source}`. A table named
  in two files keeps the first.
  """
  def sources(%Project{} = project) do
    for c <- Connectors.local(project),
        c.error == nil,
        spec <- c[:tables] || [],
        reduce: %{} do
      acc ->
        if Map.has_key?(acc, spec["name"]),
          do: acc,
          else: Map.put(acc, spec["name"], source(c, spec))
    end
  end

  defp source(c, spec) do
    %{
      kind: :api,
      connector: __MODULE__,
      api: c,
      spec: spec,
      table: spec["name"],
      db: "data.sqlite",
      config: %{},
      actions: for(t <- c.tools, t.kind == "write", into: %{}, do: {t.name, level(t.permission)}),
      every_minutes: minutes(spec["every_minutes"])
    }
  end

  @doc "What `Beamcode.SourceConnector.info/0` says, for one API table."
  def info(%{api: c}) do
    %{
      id: "api:" <> c.name,
      name: c.name,
      short: c.name |> String.first() |> String.upcase(),
      secret: c[:secret],
      table: nil,
      config_key: nil,
      actions:
        for t <- c.tools, t.kind == "write", into: %{} do
          {t.name,
           %{
             label: t.description || t.name,
             default: level(t.permission),
             needs_row: needs_row?(t)
           }}
        end
    }
  end

  # An action works on a row when its path or body takes the row's id.
  defp needs_row?(t), do: "id" in (Connectors.path_params(t) ++ Connectors.body_params(t))

  @doc "Pulls a table: the `Beamcode.SourceConnector.pull/2` shape."
  def pull(%Project{} = project, %{api: c, spec: spec}) do
    with %{} = t <-
           Connectors.find_tool(c, spec["call"]) ||
             {:error, "#{c.name} has no call #{spec["call"]}"},
         {:ok, items, full} <- pages(project, c, t, args(spec), spec, pages(spec), []) do
      columns = columns(spec)
      id_path = spec["id"] || "id"

      rows =
        for item <- items, id = dig(item, id_path), id not in [nil, ""] do
          Map.new(columns, fn {col, path, type, _} -> {col, value(dig(item, path), type)} end)
          |> Map.put("_remote_id", to_string(id))
        end
        |> Enum.uniq_by(& &1["_remote_id"])

      {:ok,
       %{
         title: spec["title"] || "#{c.name} · #{spec["name"]}",
         url: nil,
         remote_id: nil,
         columns: for({col, _, type, _} <- columns, do: {col, sql_type(type)}),
         rows: rows,
         fields:
           for {col, _, type, options} <- columns do
             %{column: col, label: col, type: type, remote_id: nil, options: options}
           end,
         full: full
       }}
    end
  end

  defp args(spec), do: if(is_map(spec["args"]), do: spec["args"], else: %{})

  defp pages(spec) do
    case spec["pages"] do
      n when is_integer(n) and n >= 1 -> min(n, @max_pages)
      _ -> @default_pages
    end
  end

  # Every page's rows, and whether that was all of them (rows missing from a
  # full pull were deleted on the service).
  defp pages(_project, _c, _t, _args, _spec, 0, acc), do: {:ok, acc, false}

  defp pages(project, c, t, args, spec, left, acc) do
    with {:ok, json} <- fetch(project, c, t, args) do
      rows =
        case dig(json, spec["rows"] || "") do
          list when is_list(list) -> list
          nil -> []
          one -> [one]
        end

      acc = acc ++ rows

      case next(json, spec, args, t) do
        nil -> {:ok, acc, true}
        {:url, url} -> follow(project, c, url, spec, left - 1, acc)
        {:args, args} -> pages(project, c, t, args, spec, left - 1, acc)
      end
    end
  end

  # `next` is a whole URL: later pages are plain GETs.
  defp follow(_project, _c, _url, _spec, 0, acc), do: {:ok, acc, false}

  defp follow(project, c, url, spec, left, acc) do
    with {:ok, json} <- decode(Connectors.request_url(project, c, url)) do
      rows = List.wrap(dig(json, spec["rows"] || ""))
      acc = acc ++ rows

      case next(json, spec, %{}, nil) do
        {:url, url} when rows != [] -> follow(project, c, url, spec, left - 1, acc)
        _ -> {:ok, acc, true}
      end
    end
  end

  defp next(json, %{"next" => path}, _args, _t) when is_binary(path) do
    case dig(json, path) do
      url when is_binary(url) and url != "" -> {:url, url}
      _ -> nil
    end
  end

  defp next(json, %{"cursor" => %{"from" => from, "to" => to}}, args, t)
       when is_binary(from) and is_binary(to) and t != nil do
    case dig(json, from) do
      cursor when cursor in [nil, ""] ->
        nil

      cursor ->
        # A call with a body template (GraphQL) takes it as one of its values,
        # anything else as a query parameter.
        if to in Connectors.body_params(t) or to in Connectors.path_params(t),
          do: {:args, Map.put(args, to, cursor)},
          else: {:args, Map.update(args, "query", %{to => cursor}, &Map.put(&1, to, cursor))}
    end
  end

  defp next(_json, _spec, _args, _t), do: nil

  defp fetch(project, c, t, args), do: decode(Connectors.request(project, c, t, args))

  defp decode({:ok, status, body}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"errors" => [_ | _] = errors, "data" => data}} when data in [nil, %{}] ->
        {:error, errors |> Enum.map(&(&1["message"] || inspect(&1))) |> Enum.join("; ")}

      {:ok, json} ->
        {:ok, json}

      _ ->
        {:error, "The response isn't JSON"}
    end
  end

  defp decode({:ok, status, body}),
    do: {:error, "HTTP #{status}: #{body |> String.slice(0, 300) |> String.trim()}"}

  defp decode(error), do: error

  # [{column, path, type, options}]
  defp columns(spec) do
    for {col, s} <- Enum.sort(spec["columns"]) do
      case s do
        path when is_binary(path) ->
          {col, path, "text", []}

        %{"path" => path} = s ->
          type = if s["type"] in @types, do: s["type"], else: "text"
          {col, to_string(path), type, List.wrap(s["options"]) |> Enum.map(&to_string/1)}

        _ ->
          {col, col, "text", []}
      end
    end
  end

  defp sql_type("integer"), do: "integer"
  defp sql_type("real"), do: "real"
  defp sql_type(_), do: "text"

  @doc """
  The value at `path` in `data` (see the module doc for the syntax). `[]`
  gives a list; everything else one value or nil.
  """
  def dig(data, path) when is_binary(path), do: walk(data, segments(path))

  defp segments(path) do
    Regex.scan(~r/\[([^\]]*)\]|([^.\[\]]+)/, path)
    |> Enum.map(fn
      [_, "", key] -> {:key, key}
      [_, ""] -> :each
      [_, inner | _] -> bracket(inner)
    end)
  end

  defp bracket(inner) do
    cond do
      inner =~ ~r/^\d+$/ -> {:index, String.to_integer(inner)}
      String.contains?(inner, "=") -> List.to_tuple([:find | String.split(inner, "=", parts: 2)])
      true -> {:key, inner}
    end
  end

  defp walk(data, []), do: data
  defp walk(nil, _), do: nil
  defp walk(%{} = map, [{:key, k} | rest]), do: walk(Map.get(map, k), rest)

  defp walk(list, [:each | rest]) when is_list(list) do
    list
    |> Enum.map(&walk(&1, rest))
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp walk(list, [{:index, i} | rest]) when is_list(list), do: walk(Enum.at(list, i), rest)

  defp walk(list, [{:find, k, v} | rest]) when is_list(list),
    do: walk(Enum.find(list, &(to_string(dig(&1, k)) == v)), rest)

  defp walk(_, _), do: nil

  defp value(nil, _type), do: nil
  defp value(v, "json"), do: Jason.encode!(v)
  defp value(list, type) when is_list(list), do: list |> Enum.map(&value(&1, type)) |> join()
  defp value(v, _type) when is_map(v), do: Jason.encode!(v)
  defp value(true, _), do: 1
  defp value(false, _), do: 0

  defp value(v, "time") when is_number(v) do
    ms = if v > 100_000_000_000, do: trunc(v), else: trunc(v * 1000)
    DateTime.from_unix!(ms, :millisecond) |> DateTime.to_iso8601()
  end

  defp value(v, "integer") when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp value(v, "real") when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp value(v, "text") when is_number(v), do: v
  defp value(v, _type), do: v

  defp join(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      vs -> Enum.map_join(vs, ", ", &to_string/1)
    end
  end

  ## Actions

  @doc """
  Sets an action's level by changing its call's permission in the API file,
  so the agent's gateway and the Outbox follow the same setting.
  """
  def set_level(%Project{} = project, c, action, level) do
    with %{kind: "write"} <-
           Connectors.find_tool(c, action) || {:error, "#{c.name} has no action #{action}"},
         {:ok, %{"tools" => tools} = json} <- Jason.decode(c.raw) do
      spec =
        case tools[action] do
          [method, path, _ | rest] -> [method, path, permission(level) | rest]
          %{} = spec -> Map.put(spec, "permission", permission(level))
        end

      Connectors.save(
        project,
        c.name,
        Jason.encode!(put_in(json, ["tools", action], spec), pretty: true) <> "\n"
      )
    else
      %{} -> {:error, "#{action} only reads"}
      {:ok, _} -> {:error, "#{c.name}.json has no tools"}
      error -> error
    end
  end

  @doc """
  An action before it's queued: `{:ok, patch, label}`. The patch is the
  call's `patch` (columns to set on the row at once) filled from the args.
  """
  def prepare(%{api: c}, action, args, row, _fields) do
    case Connectors.find_tool(c, action) do
      %{kind: "write"} = t ->
        values = values(args, row)
        patch = Connectors.fill(t.patch || %{}, values)

        label =
          case patch |> Enum.map(fn {k, v} -> "#{k} → #{v}" end) do
            [] -> t.description || action
            changes -> Enum.join(changes, ", ")
          end

        label = if row, do: "#{label} (#{row_name(row)})", else: label
        {:ok, patch, label}

      _ ->
        {:error, "#{c.name} has no action #{action}"}
    end
  end

  @doc "Posts an action: `:ok` or `{:error, message}`."
  def post(%Project{} = project, %{api: c}, action, args, row) do
    case Connectors.find_tool(c, action) do
      nil ->
        {:error, "#{c.name} has no action #{action}"}

      t ->
        values = values(args, row)

        call_args =
          values
          |> Map.put_new("query", args["query"])
          |> then(fn a ->
            if is_map(args["body"]), do: Map.put(a, "body", args["body"]), else: a
          end)

        case Connectors.request(project, c, t, call_args) do
          {:ok, status, _} when status in 200..299 -> :ok
          {:ok, status, body} -> {:error, "HTTP #{status}: #{String.slice(body, 0, 300)}"}
          error -> error
        end
    end
  end

  # What fills an action's path and body: the row's columns, `id` (the row's
  # remote id), then the args, which win.
  defp values(args, row) do
    from_row =
      if row,
        do:
          row
          |> Map.reject(fn {k, _} -> String.starts_with?(k, "_") end)
          |> Map.put("id", row["_remote_id"]),
        else: %{}

    Map.merge(from_row, Map.drop(args || %{}, ["query", "body"]))
  end

  defp row_name(row),
    do: row["title"] || row["subject"] || row["name"] || row["_remote_id"]

  defp minutes(m) when is_number(m) and m >= 1, do: m
  defp minutes(_), do: @default_minutes
end
