defmodule Beamcode.Patch do
  @moduledoc """
  Makes a unified diff small enough to show. OpenCode's session diff has each
  file whole as context (one hunk over the entire file), so a 600-line change
  to a big generated file comes as 80 000 lines. `trim/2` keeps the changed
  lines and a few around them, as new hunks, and stops after `max_lines`.
  """

  @doc """
  `{patch, hidden}`: the patch with `context` lines around each change, at most
  `max_lines` hunk lines, each cut to `max_width`; `hidden` is how many lines
  were left out after the cap.
  """
  def trim(patch, opts \\ []) when is_binary(patch) do
    context = Keyword.get(opts, :context, 3)
    max_lines = Keyword.get(opts, :max_lines, 1500)
    max_width = Keyword.get(opts, :max_width, 500)

    {header, body} =
      patch |> String.split("\n") |> Enum.split_while(&(not String.starts_with?(&1, "@@")))

    lines =
      body
      |> hunks()
      |> Enum.flat_map(&rehunk(&1, context))
      |> Enum.map(&String.slice(&1, 0, max_width))

    {shown, rest} = Enum.split(lines, max_lines)
    {Enum.join(header ++ shown, "\n"), length(rest)}
  end

  # The hunks as {old_start, new_start, lines}.
  defp hunks(body) do
    body
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)/, line) do
          [_, a, b] ->
            next = {String.to_integer(a), String.to_integer(b), []}
            if acc, do: {:cont, close(acc), next}, else: {:cont, next}

          nil when acc == nil ->
            {:cont, acc}

          nil ->
            {a, b, ls} = acc
            {:cont, {a, b, [line | ls]}}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, close(acc), nil}
      end
    )
  end

  defp close({a, b, ls}), do: {a, b, ls |> Enum.reverse() |> Enum.reject(&(&1 == ""))}

  # One hunk as the smaller hunks around its changes.
  defp rehunk({a, b, lines}, context) do
    {numbered, _} =
      Enum.map_reduce(lines, {a, b}, fn line, {a, b} ->
        next =
          case line do
            "+" <> _ -> {a, b + 1}
            "-" <> _ -> {a + 1, b}
            "\\" <> _ -> {a, b}
            _ -> {a + 1, b + 1}
          end

        {{line, a, b}, next}
      end)

    changed = Enum.map(numbered, fn {line, _, _} -> change?(line) end)
    near = near(changed, context)

    numbered
    |> Enum.zip(near)
    |> Enum.chunk_by(fn {_, keep} -> keep end)
    |> Enum.filter(fn [{_, keep} | _] -> keep end)
    |> Enum.flat_map(fn group ->
      group = Enum.map(group, fn {item, _} -> item end)
      [{_, a, b} | _] = group
      lines = Enum.map(group, fn {line, _, _} -> line end)
      old = Enum.count(lines, &(not String.starts_with?(&1, ["+", "\\"])))
      new = Enum.count(lines, &(not String.starts_with?(&1, ["-", "\\"])))
      a = if old == 0, do: max(a - 1, 0), else: a
      b = if new == 0, do: max(b - 1, 0), else: b
      ["@@ -#{a},#{old} +#{b},#{new} @@" | lines]
    end)
  end

  defp change?("+" <> _), do: true
  defp change?("-" <> _), do: true
  defp change?(_), do: false

  # Whether each line is within `context` lines of a change.
  defp near(changed, context) do
    after_change = distances(changed)
    before_change = changed |> Enum.reverse() |> distances() |> Enum.reverse()
    Enum.zip_with(after_change, before_change, &(min(&1, &2) <= context))
  end

  # For each line, how far back the last change is.
  defp distances(changed) do
    {out, _} =
      Enum.map_reduce(changed, :infinity, fn
        true, _ -> {0, 0}
        false, :infinity -> {:infinity, :infinity}
        false, d -> {d + 1, d + 1}
      end)

    out
  end
end
