defmodule Beamcode.Tickets do
  @moduledoc """
  The tasks a Folder tracks with `tk`: markdown files in `.tickets/` next to
  its code. They are read here, and created and moved with the `tk` command on
  the OpenCode server, so the files stay exactly what the agents read and write.
  """
  alias Beamcode.Opencode
  alias Beamcode.Projects.Project

  @dir ".tickets"
  @types ~w(bug feature task epic chore)
  @statuses ~w(open in_progress closed)

  @doc "The Folder's tasks, active first, then by priority and age. `{:ok, [ticket]}`."
  def list(%Project{} = project) do
    case Opencode.list_dir(project.directory, @dir) do
      {:ok, entries} ->
        tickets =
          entries
          |> Enum.filter(&(&1["type"] == "file" and String.ends_with?(&1["path"], ".md")))
          |> Enum.map(fn %{"path" => path} ->
            case Opencode.read_file(project.directory, path) do
              {:ok, body} -> parse(body)
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(&{-rank(&1["status"]), &1["priority"], &1["created"]})

        {:ok, tickets}

      # A Folder that doesn't use tickets yet (no `.tickets/`): none.
      _ ->
        {:ok, []}
    end
  end

  defp rank("in_progress"), do: 3
  defp rank("open"), do: 2
  defp rank("closed"), do: 1
  defp rank(_), do: 0

  @doc "Queues a task: `attrs` is `title`, and optional `description`, `type`, `priority`."
  def create(%Project{} = project, attrs) when is_map(attrs) do
    title = attrs |> Map.get("title", "") |> to_string() |> String.trim()
    desc = attrs |> Map.get("description", "") |> to_string() |> String.trim()
    type = attrs |> Map.get("type", "task") |> to_string()
    priority = attrs |> Map.get("priority") |> to_string()

    cond do
      title == "" ->
        {:error, "Give the task a title."}

      type not in @types ->
        {:error, "Unknown task type."}

      priority not in ["", "0", "1", "2", "3", "4"] ->
        {:error, "Priority is 0 (highest) to 4."}

      true ->
        args =
          ["create", q(title)] ++
            if(desc != "", do: ["-d", q(desc)], else: []) ++
            ["-t", type] ++
            if(priority != "", do: ["-p", priority], else: [])

        case Opencode.run_shell(project.directory, "tk " <> Enum.join(args, " "), 30_000) do
          {:ok, 0, out} -> {:ok, %{"id" => out |> String.trim() |> String.split() |> List.last()}}
          {:ok, _, out} -> {:error, String.trim(out)}
          error -> error
        end
    end
  end

  @doc "Moves a task to `status` (open | in_progress | closed)."
  def set_status(%Project{} = project, id, status)
      when is_binary(id) and status in @statuses do
    with :ok <- valid_id(id) do
      case Opencode.run_shell(project.directory, "tk status #{q(id)} #{status}", 30_000) do
        {:ok, 0, _} -> :ok
        {:ok, _, out} -> {:error, String.trim(out)}
        error -> error
      end
    end
  end

  def set_status(_project, _id, _status), do: {:error, "Unknown status."}

  @doc "Adds a timestamped note to a task (its progress log)."
  def note(%Project{} = project, id, text) when is_binary(id) and is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:error, "Write a note first."}
    else
      with :ok <- valid_id(id) do
        case Opencode.run_shell(project.directory, "tk add-note #{q(id)} #{q(text)}", 30_000) do
          {:ok, 0, _} -> :ok
          {:ok, _, out} -> {:error, String.trim(out)}
          error -> error
        end
      end
    end
  end

  @doc """
  The tasks in each folder of `dirs` (a Folder's main and its worktrees), read
  in one shell call: `%{dir => [ticket]}`, each list sorted like `list/1`.
  """
  def list_trees(_project, []), do: %{}

  def list_trees(%Project{} = project, dirs) do
    # `find`, not a glob: OpenCode's shell may be zsh, which aborts the whole
    # script on a glob that matches nothing (a tree with no tasks yet).
    script =
      Enum.map_join(dirs, "\n", fn d ->
        "printf '\\036D %s\\n' #{q(d)}; " <>
          "find #{q(d)}/#{@dir} -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort | " <>
          "while IFS= read -r f; do printf '\\036F\\n'; cat \"$f\"; done"
      end)

    case Opencode.run_shell(project.directory, script <> "\ntrue", 30_000) do
      {:ok, 0, out} -> parse_trees(out)
      _ -> %{}
    end
  end

  defp parse_trees(out) do
    out
    |> String.split("\x1eD ", trim: true)
    |> Map.new(fn chunk ->
      [dir | files] = String.split(chunk, "\x1eF\n")

      tickets =
        files
        |> Enum.map(&parse/1)
        |> Enum.filter(& &1["id"])
        |> Enum.sort_by(&{-rank(&1["status"]), &1["priority"], &1["created"]})

      {String.trim(dir), tickets}
    end)
  end

  @doc "Makes task `id` wait on `dep` (`on: true`) or stop waiting on it."
  def dep(%Project{} = project, id, dep, on) when is_binary(id) and is_binary(dep) do
    with :ok <- valid_id(id), :ok <- valid_id(dep) do
      cmd = if on, do: "dep", else: "undep"
      tk(project, "#{cmd} #{q(id)} #{q(dep)}")
    end
  end

  @doc "Deletes task `id`'s file."
  def delete(%Project{} = project, id) when is_binary(id) do
    with :ok <- valid_id(id) do
      case Opencode.run_shell(project.directory, "rm -f #{q(path(id))}", 30_000) do
        {:ok, 0, _} -> :ok
        {:ok, _, out} -> {:error, String.trim(out)}
        error -> error
      end
    end
  end

  @doc "Task `id`'s file as it is, to move it to another tree with `put/3`."
  def raw(%Project{} = project, id) when is_binary(id) do
    with :ok <- valid_id(id), do: Opencode.read_file(project.directory, path(id))
  end

  @doc "Writes a task file read with `raw/2`."
  def put(%Project{} = project, id, raw) when is_binary(id) and is_binary(raw) do
    with :ok <- valid_id(id),
         {:ok, _} <- Opencode.write_file(project.directory, path(id), raw),
         do: :ok
  end

  @doc """
  Changes task `id`'s file: `title`, `body` (the text above `## Notes`),
  `priority` (0-4) and `paused` (a `paused` tag) where given. `tk` has no
  command for these, so the file is rewritten; everything else stays.
  """
  def edit(%Project{} = project, id, attrs) when is_binary(id) and is_map(attrs) do
    with :ok <- valid_id(id),
         {:ok, raw} <- Opencode.read_file(project.directory, path(id)),
         {:ok, next} <- rewrite(raw, attrs) do
      if next == raw, do: :ok, else: put(project, id, next)
    end
  end

  @doc false
  def rewrite(raw, attrs) do
    raw = String.replace(raw, "\r\n", "\n")
    {front, rest} = split_front(raw)
    title = attrs |> Map.get("title") |> trimmed()
    body = attrs |> Map.get("body") |> then(&(&1 && String.trim(to_string(&1))))

    cond do
      Map.has_key?(attrs, "title") and title in [nil, ""] ->
        {:error, "Give the task a title."}

      Map.has_key?(attrs, "priority") and attrs["priority"] not in [0, 1, 2, 3, 4] ->
        {:error, "Priority is 0 (highest) to 4."}

      true ->
        front =
          front
          |> put_front("priority", attrs["priority"])
          |> put_paused(attrs["paused"])

        rest = rest |> put_title(title) |> put_body(body)
        {:ok, "---\n" <> front <> "\n---\n" <> rest}
    end
  end

  defp trimmed(nil), do: nil
  defp trimmed(v), do: v |> to_string() |> String.trim()

  defp put_front(front, _key, nil), do: front

  defp put_front(front, key, value) do
    line = "#{key}: #{value}"
    lines = String.split(front, "\n")

    if Enum.any?(lines, &String.starts_with?(&1, key <> ":")),
      do:
        Enum.map_join(lines, "\n", &if(String.starts_with?(&1, key <> ":"), do: line, else: &1)),
      else: front <> "\n" <> line
  end

  defp put_paused(front, nil), do: front

  defp put_paused(front, paused) do
    tags = front |> parse_front() |> Map.get("tags", [])
    tags = if is_list(tags), do: tags, else: []
    tags = if paused, do: Enum.uniq(tags ++ ["paused"]), else: tags -- ["paused"]
    put_front(front, "tags", "[" <> Enum.join(tags, ", ") <> "]")
  end

  defp put_title(rest, nil), do: rest

  defp put_title(rest, title) do
    if Regex.match?(~r/^# .*$/m, rest),
      do: Regex.replace(~r/^# .*$/m, rest, "# " <> title, global: false),
      else: "# " <> title <> "\n\n" <> rest
  end

  # The body sits between the `# Title` line and the first `## ` section.
  defp put_body(rest, nil), do: rest

  defp put_body(rest, body) do
    {head, tail} =
      case Regex.split(~r/^## /m, rest, parts: 2) do
        [head, tail] -> {head, "## " <> tail}
        [head] -> {head, ""}
      end

    title_line =
      head |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "# ")) || ""

    pre =
      head |> String.split("\n") |> Enum.take_while(&(not String.starts_with?(&1, "# ")))

    head =
      Enum.join(pre, "\n") <>
        title_line <> "\n\n" <> if(body == "", do: "", else: body <> "\n\n")

    String.trim_leading(head, "\n") <> tail
  end

  defp path(id), do: @dir <> "/" <> id <> ".md"

  defp tk(project, args) do
    case Opencode.run_shell(project.directory, "tk " <> args, 30_000) do
      {:ok, 0, _} -> :ok
      {:ok, _, out} -> {:error, String.trim(out)}
      error -> error
    end
  end

  defp valid_id(id) do
    if Regex.match?(~r/^[\w][\w.-]*$/, id) and not String.contains?(id, ".."),
      do: :ok,
      else: {:error, "That task id looks wrong."}
  end

  ## Parsing: frontmatter plus `# Title`, body and `## Notes`

  @doc "A ticket file's frontmatter, title, body and notes."
  def parse(body) do
    body = String.replace(body, "\r\n", "\n")
    {front, rest} = split_front(body)
    attrs = parse_front(front)
    {title, text, notes} = parse_body(rest)

    %{
      "id" => attrs["id"],
      "title" => title,
      "status" => attrs["status"] || "open",
      "type" => attrs["type"] || "task",
      "priority" => attrs["priority"] || 2,
      "assignee" => attrs["assignee"],
      "tags" => List.wrap(attrs["tags"] || []),
      "deps" => attrs["deps"] || [],
      "created" => attrs["created"],
      "body" => text,
      "notes" => notes
    }
  end

  defp split_front("---\n" <> rest) do
    case String.split(rest, ~r/\n---\n/, parts: 2) do
      [front, body] -> {front, body}
      _ -> {"", rest}
    end
  end

  defp split_front(body), do: {"", body}

  defp parse_front(front) do
    front
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k), value(String.trim(v)))
        _ -> acc
      end
    end)
  end

  defp value("[" <> _ = v) do
    v
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp value(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> v
    end
  end

  defp parse_body(rest) do
    lines = String.split(rest, "\n")

    title =
      Enum.find_value(lines, fn l ->
        if String.starts_with?(l, "# "), do: String.trim_leading(l, "# "), else: nil
      end) || ""

    sections = sections(lines)

    text =
      sections
      |> Map.get("", [])
      |> Enum.reject(&String.starts_with?(&1, "# "))
      |> Enum.join("\n")
      |> String.trim()

    {title, text, notes(Map.get(sections, "Notes", []))}
  end

  # The lines under each `## Heading`, keyed by heading ("" is before the first one).
  defp sections(lines) do
    {_, acc} =
      Enum.reduce(lines, {"", %{}}, fn line, {sec, acc} ->
        case Regex.run(~r/^##\s+(.*)$/, line) do
          [_, name] -> {name, Map.put_new(acc, name, [])}
          nil -> {sec, Map.update(acc, sec, [line], &(&1 ++ [line]))}
        end
      end)

    acc
  end

  # `tk` writes each note as a `**timestamp**` line, then its text.
  defp notes(lines) do
    {notes, current} =
      Enum.reduce(lines, {[], nil}, fn line, {notes, current} ->
        case Regex.run(~r/^\*\*(.+?)\*\*$/, line) do
          [_, at] ->
            notes = if current, do: [finish_note(current) | notes], else: notes
            {notes, {at, []}}

          nil ->
            {notes, if(current, do: {elem(current, 0), elem(current, 1) ++ [line]}, else: nil)}
        end
      end)

    notes = if current, do: [finish_note(current) | notes], else: notes
    Enum.reverse(notes)
  end

  defp finish_note({at, lines}),
    do: %{"at" => at, "text" => lines |> Enum.join("\n") |> String.trim()}

  defp q(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
