defmodule Beamcode.Composer do
  @moduledoc """
  The global composer: one line, typed or spoken, that starts something from
  anywhere ("new session in amino-monorepo, use the e2e debug skill and then
  find why checkout fails on CI", "run stripe-reconcile", "what changed in
  chatos-web this week?").

  `parse/2` reads the line into an action, a target project or routine, an
  optional skill and the task; `start/3` does it. Names match loosely, so speech
  ("amino monorepo", "stripe") finds `amino-monorepo` and `stripe-reconcile`.
  """
  alias Beamcode.{Routines, Sessions}
  alias Beamcode.Projects.Project

  @type action :: :session | :run | :ask | :chat
  @type parsed :: %{
          action: action,
          project: Project.t() | nil,
          skill: String.t() | nil,
          task: String.t(),
          text: String.t()
        }

  @run_verbs ~r/\b(run|trigger|kick off|start)\b/i
  @question ~r/(\?\s*$)|(^(what|why|how|when|who|where|which|is|are|does|did|can|could|should)\b)/i

  @doc """
  Reads a composer line. `projects` are the ones the user can see. Returns nil
  for an empty line.

    * `:run` – a routine is named with run/trigger/start and no "session"
    * `:session` – a project is named (anything but a question about it)
    * `:ask` – a question about a named project; it also runs as a session
    * `:chat` – no project named; goes to the first chat project, if any
  """
  @spec parse(String.t(), [Project.t()]) :: parsed | nil
  def parse(text, projects) do
    t = String.trim(text || "")

    if t == "" do
      nil
    else
      places = Enum.filter(projects, &(&1.kind in ~w(code chat)))
      routines = Enum.filter(projects, &(&1.kind == "routine"))

      project = find_name(t, places)
      routine = find_name(t, routines)
      skill = find_skill(t)

      explicit_session = Regex.match?(~r/\bsession\b/i, t) or Regex.match?(~r/@[\w-]+/, t)
      run? = routine != nil and Regex.match?(@run_verbs, t) and not explicit_session
      question? = Regex.match?(@question, t)

      action =
        cond do
          run? -> :run
          project && (explicit_session or not question?) -> :session
          project -> :ask
          true -> :chat
        end

      s = if skill, do: String.replace(t, skill.raw, " ", global: false), else: t
      anchor = if action == :run, do: routine, else: project

      s =
        if anchor && action in [:run, :session] do
          case find_name(s, [anchor.project]) do
            nil -> s
            m -> cut_around(s, m)
          end
        else
          s
        end

      s =
        s
        |> String.replace(~r/\s{2,}/, " ")
        |> String.replace(~r/^[\s,.:;-]*(and\s+)?(then\s+)?/i, "")
        |> String.replace(~r/\s+([?.!,])/, "\\1")
        |> String.trim()

      s = if action in [:ask, :chat] and s == "", do: t, else: s

      target =
        case action do
          :run -> routine.project
          :chat -> Enum.find(places, &(&1.kind == "chat"))
          _ -> project.project
        end

      %{action: action, project: target, skill: skill && skill.name, task: s, text: t}
    end
  end

  @doc "Projects to offer when nothing was named."
  def suggestions(%{action: :chat}, projects),
    do: projects |> Enum.filter(&(&1.kind in ~w(code chat))) |> Enum.take(4)

  def suggestions(_, _), do: []

  @doc "What the preview calls the action."
  def action_label(:session), do: "New session"
  def action_label(:run), do: "Run routine"
  def action_label(:ask), do: "Ask about project"
  def action_label(:chat), do: "Chat"

  @doc "The submit button's label."
  def button_label(:run), do: "Run"
  def button_label(:session), do: "Start session"
  def button_label(_), do: "Ask"

  @doc "The first message in the new session: `/skill task` or the task."
  def prompt(%{skill: nil, task: task}), do: task
  def prompt(%{skill: skill, task: ""}), do: "/" <> skill
  def prompt(%{skill: skill, task: task}), do: "/#{skill} #{task}"

  @doc """
  Starts what `parse/2` read and returns the session to open. A run starts its
  routine; everything else starts a session in the project and sends the task.
  """
  def start(%{project: nil}, _user), do: {:error, "Say which project, e.g. “in chatos-web”."}

  def start(%{action: :run, project: project}, user) do
    with {:ok, run} <- Routines.run(project, user), do: {:ok, run.session_id}
  end

  def start(%{project: project} = parsed, user) do
    with {:ok, session} <- Sessions.start(project, user, worktree: project.always_worktree) do
      dir = get_in(session, ["location", "directory"]) || project.directory
      id = session["id"]

      with {:ok, _} <- Sessions.send_text(id, prompt(parsed), dir), do: {:ok, id}
    end
  end

  ## Matching

  # The earliest (then longest) mention of a name in `list`: as written, with
  # spaces for dashes, or (loose) its first part when that is 4+ letters.
  defp find_name(text, list) do
    t = String.downcase(text)

    list
    |> Enum.flat_map(fn p ->
      parts = String.split(p.name, "-")
      first = hd(parts)

      variants =
        [p.name, Enum.join(parts, " ")] ++
          if(length(parts) > 1 and String.length(first) >= 4, do: [first], else: [])

      for v <- Enum.uniq(variants),
          {idx, len} <- word_match(t, v),
          do: %{project: p, idx: idx, len: len}
    end)
    |> Enum.sort_by(&{&1.idx, -&1.len})
    |> List.first()
  end

  defp word_match(t, v) do
    case Regex.run(~r/(?<![\w-])#{Regex.escape(v)}(?![\w-])/u, t, return: :index) do
      [{idx, len}] -> [{byte_to_char(t, idx), String.length(binary_part(t, idx, len))}]
      nil -> []
    end
  end

  defp byte_to_char(t, idx), do: t |> binary_part(0, idx) |> String.length()

  # Drops the words that only say where: "create a new session in the @x project".
  defp cut_around(s, m) do
    head = String.slice(s, 0, m.idx)
    tail = String.slice(s, (m.idx + m.len)..-1//1)

    head =
      Regex.replace(
        ~r/((please\s+)?(create|start|open|make)\s+)?(a\s+)?(new\s+)?(session\s+)?(in|on|for)\s+(the\s+)?@?$|@$|(run|trigger|kick off|start)\s+(the\s+)?$/i,
        head,
        ""
      )

    tail = Regex.replace(~r/^\s+(project|routine)\b/i, tail, "")
    head <> " " <> tail
  end

  # `/name`, "use the e2e debug skill", "with the review skill", "code-review skill".
  defp find_skill(t) do
    patterns = [
      ~r/[,.]?\s*(and\s+)?(use|using|with)\s+(the\s+)?\/?([\w-]+(?:\s+[\w-]+){0,2})\s+skill\b/i,
      ~r/[,.]?\s*(and\s+)?(use|using|with)\s+(the\s+)?\/([\w.-]+)/i,
      ~r/(?:^|\s)\/([\w.-]+)/,
      ~r/\b([\w-]+)\s+skill\b/i
    ]

    Enum.find_value(patterns, fn re ->
      case Regex.run(re, t) do
        nil ->
          nil

        [raw | groups] ->
          name =
            groups
            |> List.last()
            |> String.downcase()
            |> String.split(~r/\s+/, trim: true)
            |> Enum.join("-")

          if name in ["the", "a", "this", "that"], do: nil, else: %{name: name, raw: raw}
      end
    end)
  end
end
