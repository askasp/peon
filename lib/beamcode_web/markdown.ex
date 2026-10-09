defmodule BeamcodeWeb.Markdown do
  @moduledoc """
  Small markdown renderer for chat messages: fenced code, headings, lists,
  quotes, paragraphs, and inline code/bold/italic/links. Everything is escaped
  first, so the output is safe.
  """

  def to_html(nil), do: {:safe, ""}

  def to_html(text) when is_binary(text) do
    text
    |> String.split(~r/^```.*$/m, include_captures: true)
    |> render_parts(false, [])
    |> IO.iodata_to_binary()
    |> then(&{:safe, &1})
  end

  # Alternates between prose and fenced code, using the ``` captures as toggles.
  defp render_parts([], _in_code, acc), do: Enum.reverse(acc)

  defp render_parts(["```" <> _ | rest], in_code, acc), do: render_parts(rest, !in_code, acc)

  defp render_parts([part | rest], true, acc) do
    code = part |> String.trim_leading("\n") |> String.trim_trailing() |> escape()
    render_parts(rest, true, [["<pre><code>", code, "</code></pre>"] | acc])
  end

  defp render_parts([part | rest], false, acc),
    do: render_parts(rest, false, [blocks(part) | acc])

  defp blocks(text) do
    text
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim(&1, "\n"))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&block/1)
  end

  # Groups consecutive lines of the same kind, so a heading followed directly
  # by bullets still renders as a heading and a list.
  defp block(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.chunk_by(&line_kind/1)
    |> Enum.flat_map(fn [first | _] = lines ->
      case line_kind(first) do
        :h ->
          Enum.map(lines, &heading/1)

        :ul ->
          [
            [
              "<ul>",
              Enum.map(
                lines,
                &["<li>", inline(Regex.replace(~r/^\s*[-*+]\s+/, &1, "")), "</li>"]
              ),
              "</ul>"
            ]
          ]

        :ol ->
          [
            [
              "<ol>",
              Enum.map(
                lines,
                &["<li>", inline(Regex.replace(~r/^\s*\d+[.)]\s+/, &1, "")), "</li>"]
              ),
              "</ol>"
            ]
          ]

        :quote ->
          [
            [
              "<blockquote>",
              inline(Enum.map_join(lines, "\n", &String.replace_prefix(&1, ">", ""))),
              "</blockquote>"
            ]
          ]

        :p ->
          [["<p>", Enum.intersperse(Enum.map(lines, &inline/1), "<br>"), "</p>"]]
      end
    end)
  end

  defp line_kind(line) do
    cond do
      Regex.match?(~r/^\#{1,6}\s/, line) -> :h
      Regex.match?(~r/^\s*[-*+]\s+/, line) -> :ul
      Regex.match?(~r/^\s*\d+[.)]\s+/, line) -> :ol
      String.starts_with?(line, ">") -> :quote
      true -> :p
    end
  end

  defp heading(line) do
    [_, hashes, title] = Regex.run(~r/^(\#{1,6})\s+(.*)$/, line)
    level = min(String.length(hashes), 3)
    ["<h#{level}>", inline(title), "</h#{level}>"]
  end

  defp inline(text) do
    text
    |> escape()
    |> String.split(~r/(`[^`]+`)/, include_captures: true)
    |> Enum.map(fn
      "`" <> rest -> ["<code>", String.trim_trailing(rest, "`"), "</code>"]
      plain -> emphasis(plain)
    end)
  end

  defp emphasis(text) do
    text
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/, &1, "<strong>\\1</strong>"))
    |> then(&Regex.replace(~r/(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])/, &1, "<em>\\1</em>"))
    |> then(
      &Regex.replace(
        ~r/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/,
        &1,
        "<a href=\"\\2\" target=\"_blank\" rel=\"noopener\">\\1</a>"
      )
    )
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
