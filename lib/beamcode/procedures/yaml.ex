defmodule Beamcode.Procedures.Yaml do
  @moduledoc """
  The YAML a procedure's front matter uses, and no more: block maps and lists,
  flow maps and lists (`{ type: text }`, `[Read, refund-policy.md]`), quoted
  and plain scalars, and full-line comments. No anchors, tags or multi-line
  strings.

  Parsed maps keep their key order under the atom key `:order` (string keys
  never collide with it), so `dump/1` writes keys back in the order they were
  read and inputs show in the order they were written.
  """

  @doc "Parses front matter text into a map. Returns `{:ok, map}` or `{:error, message}`."
  def parse(text) do
    lines =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reject(fn {l, _} ->
        String.trim(l) == "" or String.starts_with?(String.trim(l), "#")
      end)
      |> Enum.map(fn {l, n} ->
        content = String.trim_leading(l)
        {String.length(l) - String.length(content), String.trim_trailing(content), n}
      end)

    case lines do
      [] ->
        {:ok, %{order: []}}

      [{indent, _, _} | _] ->
        case block(lines, indent) do
          {value, []} when is_map(value) -> {:ok, value}
          {_, []} -> {:error, "the front matter must be a map of keys"}
          {_, [{_, _, n} | _]} -> {:error, "line #{n} is indented wrong"}
        end
    end
  catch
    {:yaml, message} -> {:error, message}
  end

  defp block([{indent, "-" <> _, _} | _] = lines, indent), do: list(lines, indent, [])
  defp block(lines, indent), do: map(lines, indent, [])

  defp map([{indent, content, n} | rest] = lines, indent, acc) do
    if list_item?(content) do
      {ordered(acc), lines}
    else
      {key, inline} = split_key(content, n)

      {value, rest} =
        cond do
          inline != "" ->
            {flow(inline, n), rest}

          match?([{i, _, _} | _] when i > indent, rest) ->
            [{i, _, _} | _] = rest
            block(rest, i)

          match?([{^indent, "-" <> _, _} | _], rest) ->
            list(rest, indent, [])

          true ->
            {nil, rest}
        end

      map(rest, indent, [{key, value} | acc])
    end
  end

  defp map(lines, _indent, acc), do: {ordered(acc), lines}

  defp list([{indent, content, n} | rest] = lines, indent, acc) do
    if list_item?(content) do
      item = content |> String.slice(1..-1//1) |> String.trim_leading()
      offset = String.length(content) - String.length(item)

      {value, rest} =
        cond do
          item == "" ->
            case rest do
              [{i, _, _} | _] when i > indent -> block(rest, i)
              _ -> {nil, rest}
            end

          map_line?(item) ->
            # "- name: Read" starts a map whose keys line up with "name".
            map([{indent + offset, item, n} | rest], indent + offset, [])

          true ->
            {flow(item, n), rest}
        end

      list(rest, indent, [value | acc])
    else
      {Enum.reverse(acc), lines}
    end
  end

  defp list(lines, _indent, acc), do: {Enum.reverse(acc), lines}

  defp list_item?(content), do: content == "-" or String.starts_with?(content, "- ")

  defp map_line?(text) do
    not String.starts_with?(text, ["{", "[", "\"", "'"]) and
      Regex.match?(~r/^[^\s:][^:]*:(\s|$)/, text)
  end

  defp split_key(content, n) do
    case Regex.run(~r/^("[^"]*"|'[^']*'|[^:]+?)\s*:(?:\s+(.*))?$/, content) do
      [_, key] -> {unquote_key(key), ""}
      [_, key, inline] -> {unquote_key(key), String.trim(inline)}
      nil -> throw({:yaml, "line #{n} needs a key, like \"name: value\""})
    end
  end

  defp unquote_key(<<q, _::binary>> = key) when q in [?", ?'], do: String.slice(key, 1..-2//1)
  defp unquote_key(key), do: String.trim(key)

  defp ordered(acc) do
    pairs = Enum.reverse(acc)
    pairs |> Map.new() |> Map.put(:order, pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq())
  end

  ## Flow values: {a: b}, [a, b], quoted strings, plain scalars

  defp flow(text, n) do
    case value(text, n, :top) do
      {v, ""} -> v
      {_, more} -> throw({:yaml, "line #{n}: unexpected \"#{more}\""})
    end
  end

  defp value("{" <> rest, n, _ctx), do: flow_map(String.trim_leading(rest), n, [])
  defp value("[" <> rest, n, _ctx), do: flow_list(String.trim_leading(rest), n, [])

  defp value(<<q, rest::binary>>, n, _ctx) when q in [?", ?'] do
    case quoted(rest, q, "") do
      {:ok, s, more} -> {s, String.trim_leading(more)}
      :error -> throw({:yaml, "line #{n}: a quote is never closed"})
    end
  end

  defp value(text, _n, :top), do: {scalar(text), ""}

  defp value(text, _n, :flow) do
    [plain | _] = String.split(text, ~r/[,\]\}]/, parts: 2)
    {scalar(plain), String.trim_leading(String.slice(text, String.length(plain)..-1//1))}
  end

  defp quoted(<<"\\", c, rest::binary>>, ?" = q, acc), do: quoted(rest, q, acc <> escape(c))
  defp quoted(<<"''", rest::binary>>, ?' = q, acc), do: quoted(rest, q, acc <> "'")
  defp quoted(<<q, rest::binary>>, q, acc), do: {:ok, acc, rest}
  defp quoted(<<c::utf8, rest::binary>>, q, acc), do: quoted(rest, q, acc <> <<c::utf8>>)
  defp quoted("", _, _), do: :error

  defp escape(?n), do: "\n"
  defp escape(?t), do: "\t"
  defp escape(c), do: <<c>>

  defp flow_map("}" <> rest, _n, acc), do: {ordered(acc), String.trim_leading(rest)}

  defp flow_map(text, n, acc) do
    {key, rest} = flow_key(text, n)
    {v, rest} = flow_entry_value(rest, n)
    flow_map(next(rest, "}", n), n, [{key, v} | acc])
  end

  defp flow_list("]" <> rest, _n, acc), do: {Enum.reverse(acc), String.trim_leading(rest)}

  defp flow_list(text, n, acc) do
    # `[stripe: read]` is a list holding the one-key map %{"stripe" => "read"}.
    {item, rest} =
      if map_line?(text) and not String.starts_with?(text, ["{", "["]) and pair_ahead?(text) do
        {key, rest} = flow_key(text, n)
        {v, rest} = flow_entry_value(rest, n)
        {ordered([{key, v}]), rest}
      else
        value(text, n, :flow)
      end

    flow_list(next(rest, "]", n), n, [item | acc])
  end

  # Whether "a: b, …" has its colon before the next comma or bracket.
  defp pair_ahead?(text) do
    case Regex.run(~r/^[^,\]\}]*?:(\s|$)/, text) do
      nil -> false
      _ -> true
    end
  end

  defp flow_key(text, n) do
    case Regex.run(~r/^("[^"]*"|'[^']*'|[^:,\]\}]+?)\s*:\s*(.*)$/s, text) do
      [_, key, rest] -> {unquote_key(key), rest}
      nil -> throw({:yaml, "line #{n}: expected \"key: value\" in { }"})
    end
  end

  defp flow_entry_value(text, n) do
    if String.starts_with?(text, [",", "}"]), do: {nil, text}, else: value(text, n, :flow)
  end

  defp next("," <> rest, _close, _n), do: String.trim_leading(rest)
  defp next(<<c, _::binary>> = rest, close, _n) when <<c>> == close, do: rest
  defp next(_, close, n), do: throw({:yaml, "line #{n}: expected \",\" or \"#{close}\""})

  defp scalar(text) do
    case String.trim(text) do
      "" -> nil
      "~" -> nil
      "null" -> nil
      "true" -> true
      "false" -> false
      s -> number(s) || s
    end
  end

  defp number(s) do
    cond do
      Regex.match?(~r/^-?\d+$/, s) -> String.to_integer(s)
      Regex.match?(~r/^-?\d+\.\d+$/, s) -> String.to_float(s)
      true -> nil
    end
  end

  ## Writing

  @doc "Front matter text for a map, keys in their `:order` (then the rest by name)."
  def dump(map) when is_map(map), do: map |> dump_map(0) |> Enum.join("\n")

  defp keys(map) do
    order = Map.get(map, :order, [])

    rest =
      map |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 in order)) |> Enum.sort()

    Enum.filter(order, &Map.has_key?(map, &1)) ++ rest
  end

  defp dump_map(map, indent) do
    pad = String.duplicate(" ", indent)

    for key <- keys(map), (v = map[key]) != nil, reduce: [] do
      acc ->
        acc ++
          case inline(v) do
            {:ok, text} -> ["#{pad}#{plain_key(key)}: #{text}"]
            :block -> ["#{pad}#{plain_key(key)}:" | dump_block(v, indent + 2)]
          end
    end
  end

  defp dump_block(list, indent) when is_list(list) do
    pad = String.duplicate(" ", indent)

    Enum.flat_map(list, fn item ->
      # Maps in a block list (steps) stay one key per line.
      case if(is_map(item) and keys(item) != [], do: :block, else: inline(item)) do
        {:ok, text} ->
          ["#{pad}- #{text}"]

        :block when is_map(item) ->
          [first | rest] = dump_map(item, indent + 2)
          ["#{pad}- " <> String.trim_leading(first) | rest]

        :block ->
          ["#{pad}-" | dump_block(item, indent + 2)]
      end
    end)
  end

  defp dump_block(map, indent) when is_map(map), do: dump_map(map, indent)

  # A value on the key's own line: a scalar, or a short flow map or list.
  defp inline(v) when is_map(v) do
    if Enum.all?(keys(v), &flat?(v[&1])) do
      text =
        "{ " <>
          Enum.map_join(keys(v), ", ", &"#{plain_key(&1)}: #{scalar_text(v[&1], :flow)}") <> " }"

      if String.length(text) <= 60,
        do: {:ok, if(text == "{  }", do: "{}", else: text)},
        else: :block
    else
      :block
    end
  end

  defp inline(v) when is_list(v) do
    if Enum.all?(
         v,
         &(flat?(&1) or (is_map(&1) and Enum.all?(keys(&1), fn k -> flat?(&1[k]) end)))
       ) do
      text = "[" <> Enum.map_join(v, ", ", &flow_item/1) <> "]"
      if String.length(text) <= 60, do: {:ok, text}, else: :block
    else
      :block
    end
  end

  defp inline(v), do: {:ok, scalar_text(v, :block)}

  defp flow_item(v) when is_map(v) do
    case keys(v) do
      [k] -> "#{plain_key(k)}: #{scalar_text(v[k], :flow)}"
      _ -> elem(inline(v), 1)
    end
  end

  defp flow_item(v), do: scalar_text(v, :flow)

  defp flat?(v), do: not is_map(v) and not is_list(v)

  defp plain_key(key) do
    if Regex.match?(~r/^[\w][\w .\/-]*$/, key), do: key, else: Jason.encode!(key)
  end

  defp scalar_text(nil, _), do: "null"
  defp scalar_text(v, _) when is_boolean(v) or is_number(v), do: to_string(v)

  defp scalar_text(v, ctx) when is_binary(v) do
    special = if ctx == :flow, do: ~r/[,\[\]\{\}]|: |\s#|:$/, else: ~r/: |\s#|:$/

    if v == "" or scalar(v) != v or String.trim(v) != v or String.contains?(v, "\n") or
         String.starts_with?(v, ~w({ [ ] } & * # ? | - < > = ! % @ ` " ' ,)) or
         Regex.match?(special, v),
       do: Jason.encode!(v),
       else: v
  end

  defp scalar_text(v, ctx), do: scalar_text(to_string(v), ctx)
end
