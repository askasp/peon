defmodule Beamcode.Speech do
  @moduledoc """
  Turns an agent reply (markdown, code, file paths) into a line worth saying
  out loud: the first sentence or two, plus the closing question if it asks
  one. Code blocks and tables are left to the screen; paths become a short
  name ("lib/beamcode/sessions.ex" → "sessions"), links their text.

  The same text serves the browser now and a phone line later.
  """

  @max_words 40
  @max_sentences 2

  @doc "A short, plain version of `markdown` for text-to-speech. \"\" when there is nothing to say."
  def speakable(markdown, opts \\ []) do
    max_words = Keyword.get(opts, :max_words, @max_words)

    sentences =
      (markdown || "")
      |> String.replace(~r/```.*?(```|\z)/s, "\n\n")
      |> String.replace(~r/<[^>]+>/, " ")
      |> String.split("\n")
      # Tables, rules and headings are for the eye.
      |> Enum.reject(&Regex.match?(~r/^\s*(\|.*\||[-=*_]{3,}|\#{1,6}\s.*)\s*$/, &1))
      |> Enum.map(&clean_line/1)
      |> Enum.join("\n")
      |> sentences()

    case sentences do
      [] ->
        ""

      [first | rest] ->
        picked = take_words([first | rest], max_words)
        last = List.last(rest)

        picked =
          if last != nil and String.ends_with?(last, "?") and last not in picked and
               words(last) <= 20,
             do: picked ++ [last],
             else: picked

        Enum.join(picked, " ")
    end
  end

  # One markdown line to plain words; empty lines stay as paragraph breaks.
  defp clean_line(line) do
    line
    |> String.replace(~r/^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/, "")
    |> String.replace(~r/^\s*>\s?/, "")
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/`([^`]*)`/, fn whole -> code(String.slice(whole, 1..-2//1)) end)
    |> String.replace(~r/https?:\/\/\S+/, "a link")
    |> String.replace(
      ~r/(?<![\w@])(?:~|\.{1,2})?\/?(?:[\w.@-]+\/)+[\w.@-]+(?::\d+(?:-\d+)?)?/,
      &path/1
    )
    |> String.replace(
      ~r/\b[\w-]+\.(ex|exs|heex|js|ts|tsx|jsx|css|json|md|py|rb|go|rs|ya?ml|toml|sh|sql|html)(:\d+)?\b/,
      &path/1
    )
    |> String.replace(~r/(\*\*|__|~~)(.+?)\1/, "\\2")
    |> String.replace(~r/(?<![\w*])[*_](\S.*?\S|\S)[*_](?![\w*])/, "\\1")
    |> String.replace(~r/\s*[→←↔⇒]\s*/u, ", ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> end_sentence()
  end

  # A list item or heading without a full stop still ends a sentence.
  defp end_sentence(""), do: ""

  defp end_sentence(line),
    do: if(Regex.match?(~r/[.!?:]$/, line), do: line, else: line <> ".")

  # Inline code: keep a short word-like name, drop anything else.
  defp code(inner) do
    cond do
      String.contains?(inner, "/") or Regex.match?(~r/\.\w{1,5}(:\d+)?$/, inner) -> path(inner)
      Regex.match?(~r/^[\w .-]{1,24}$/, inner) -> inner |> String.replace(~r/[_-]/, " ")
      true -> ""
    end
  end

  # "lib/beamcode_web/live/session_live.ex:42" → "session live"
  defp path(p) do
    p
    |> String.replace(~r/:\d+(-\d+)?$/, "")
    |> String.trim_trailing("/")
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(~r/[_.-]+/, " ")
    |> String.trim()
  end

  defp sentences(text) do
    text
    |> String.split(~r/\n\s*\n|\n/)
    |> Enum.flat_map(&String.split(&1, ~r/(?<=[.!?])\s+(?=[A-Z0-9"“])/u))
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.replace(&1, ~r/\s+([,.!?:;])/, "\\1"))
    |> Enum.map(&String.replace(&1, ~r/:$/, "."))
    |> Enum.reject(&(&1 in ["", "."] or not Regex.match?(~r/\w/u, &1)))
  end

  # Whole sentences up to `max` words; always at least the first (cut if long).
  defp take_words([first | rest], max) do
    if words(first) >= max do
      [first |> String.split() |> Enum.take(max) |> Enum.join(" ") |> Kernel.<>("…")]
    else
      Enum.reduce_while(rest, {[first], words(first)}, fn s, {acc, n} ->
        if length(acc) < @max_sentences and n + words(s) <= max,
          do: {:cont, {acc ++ [s], n + words(s)}},
          else: {:halt, {acc, n}}
      end)
      |> elem(0)
    end
  end

  defp words(s), do: s |> String.split() |> length()
end
