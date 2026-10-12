defmodule Beamcode.Composer do
  @moduledoc """
  The global composer: one line, typed or spoken, that starts something from
  anywhere ("new session in amino-monorepo, use the e2e debug skill and then
  find why checkout fails on CI", "run stripe-reconcile", "what changed in
  chatos-web this week?").

  `parse/3` reads the line into an action, a target project or routine, an
  optional skill, model and agent, and the task; `start/2` does it. Names match loosely, so speech
  ("amino monorepo", "stripe") finds `amino-monorepo` and `stripe-reconcile`.

  It is plain rules, no model: the preview has to follow along word by word
  while you talk. Status questions ("what's the status of the latest session in
  amino-monorepo?", "anything waiting?") are answered by Peon itself from live
  session data (`Beamcode.Composer.Status`), not by an agent.
  """
  alias Beamcode.{Routines, Sessions}
  alias Beamcode.Composer.Catalog
  alias Beamcode.Projects.Project

  @type action :: :session | :run | :ask | :chat | :status
  @type parsed :: %{
          action: action,
          project: Project.t() | nil,
          status: :latest | :overview | nil,
          sure: boolean,
          skill: String.t() | nil,
          use_model: Catalog.model() | nil,
          agent: String.t() | nil,
          task: String.t(),
          text: String.t()
        }

  @run_verbs ~r/\b(run|trigger|kick off|start)\b/i
  @question ~r/(\?\s*$)|(^(what|what's|whats|why|how|how's|when|who|where|which|is|are|does|did|can|could|should|has|have|any)\b)/i
  # "new session", "start a session", "create a new session": only these mean a new one.
  @create_session ~r/\b(new|start|create|open|make|spin up)\b(\s+[\w-]+){0,2}\s+session\b/i
  @status_words ~r/\b(status|progress|going on|happening|running|waiting|working on|sessions?|runs?)\b/i
  @status_lead ~r/^(status|show|list|check|give me|tell me|anything|any)\b/i
  @latest ~r/\b(latest|last|newest|most recent|current)\b/i
  @plural ~r/\b(all|every|sessions|runs)\b/i

  @doc """
  Reads a composer line. `projects` are the ones the user can see; `catalog`
  (`Beamcode.Composer.Catalog`) has the models and agents the line may name
  ("using opus", "with the plan agent"). Returns nil for an empty line. `sure` is true only for plain, unambiguous lines ("run
  stripe-reconcile", "new session in X, …", "anything waiting?"); everything
  else goes to the model on Enter.

    * `:status` – a question about sessions or progress; Peon answers it.
      `status: :latest` for "the latest/last session", else `:overview`.
      The project (or routine) is optional
    * `:run` – a routine is named with run/trigger/start and no "new session"
    * `:session` – a project is named (anything but a question about it)
    * `:ask` – a question about a named project; it also runs as a session
    * `:chat` – no project named; goes to the first chat project, if any
  """
  @spec parse(String.t(), [Project.t()], map) :: parsed | nil
  def parse(text, projects, catalog \\ %{}) do
    t = String.trim(text || "")

    if t == "" do
      nil
    else
      places = Enum.filter(projects, &(&1.kind == "code" or Project.chat_like?(&1)))
      routines = Enum.filter(projects, &(&1.kind == "routine"))

      project = find_name(t, places)
      routine = find_name(t, routines)
      skill = find_skill(t)

      create? = Regex.match?(@create_session, t)
      explicit_session = create? or Regex.match?(~r/@[\w-]+/, t)
      run? = routine != nil and Regex.match?(@run_verbs, t) and not explicit_session
      question? = Regex.match?(@question, t)

      status? =
        not create? and Regex.match?(@status_words, t) and
          (question? or Regex.match?(@status_lead, t))

      action =
        cond do
          status? -> :status
          run? -> :run
          project && (explicit_session or not question?) -> :session
          project -> :ask
          true -> :chat
        end

      s = if skill, do: String.replace(t, skill.raw, " ", global: false), else: t
      agent = find_agent(s, catalog[:agents] || [])
      s = if agent, do: String.replace(s, agent.raw, " ", global: false), else: s
      use_model = find_model(s, catalog[:models] || [], catalog[:default_provider])
      s = if use_model, do: String.replace(s, use_model.raw, " ", global: false), else: s
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
        # "use opus to fix it" → "fix it".
        |> then(&if(use_model || agent, do: String.replace(&1, ~r/^to\s+/i, ""), else: &1))
        |> String.replace(~r/\s+([?.!,])/, "\\1")
        |> String.replace(~r/([\s,;:]+(and|then))+$/i, "")
        |> String.replace(~r/[\s,;:]+$/, "")
        |> String.trim()

      s = if action in [:ask, :chat] and s == "", do: t, else: s

      target =
        case action do
          :status -> earliest(project, routine)
          :run -> routine.project
          :chat -> chat_place(places)
          _ -> project.project
        end

      status =
        cond do
          action != :status -> nil
          Regex.match?(@latest, t) and not Regex.match?(@plural, t) -> :latest
          true -> :overview
        end

      skill = if action == :status, do: nil, else: skill && skill.name
      session? = action in [:session, :ask, :chat]
      use_model = if session? and use_model, do: use_model.model
      agent = if session? and agent, do: agent.name
      task = if action == :status, do: t, else: s

      sure =
        case action do
          :status -> Regex.match?(~r/\b(sessions?|runs?|waiting|running)\b/i, t)
          :run -> leftover_words(s) <= 1
          :session -> explicit_session and s != ""
          _ -> false
        end

      %{
        action: action,
        project: target,
        status: status,
        skill: skill,
        use_model: use_model,
        agent: agent,
        task: task,
        text: t,
        sure: sure
      }
    end
  end

  # Words left in a run line besides filler ("run routine x now" → 0).
  defp leftover_words(s) do
    s
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}-]+/u, trim: true)
    |> Enum.reject(
      &(&1 in ~w(run the routine procedure now please it again kick off trigger start))
    )
    |> length()
  end

  defp earliest(nil, nil), do: nil
  defp earliest(a, nil), do: a.project
  defp earliest(nil, b), do: b.project
  defp earliest(a, b), do: if(a.idx <= b.idx, do: a.project, else: b.project)

  @doc "Where a general chat goes: the user's Home folder, else the first chat folder."
  def chat_place(projects),
    do: Enum.find(projects, &(&1.kind == "home")) || Enum.find(projects, &(&1.kind == "chat"))

  @doc "What the preview calls the action."
  def action_label(:session), do: "New session"
  def action_label(:run), do: "Run procedure"
  def action_label(:ask), do: "Ask about project"
  def action_label(:chat), do: "Chat"
  def action_label(:status), do: "Status (Peon answers)"

  @doc "The submit button's label."
  def button_label(:run), do: "Run"
  def button_label(:status), do: "Answer"
  def button_label(:session), do: "Start session"
  def button_label(_), do: "Ask"

  @doc "The first message in the new session: `/skill task` or the task."
  def prompt(%{skill: nil, task: task}), do: task
  def prompt(%{skill: skill, task: ""}), do: "/" <> skill
  def prompt(%{skill: skill, task: task}), do: "/#{skill} #{task}"

  @doc """
  Starts what `parse/2` read and returns the session to open. A run starts its
  routine; everything else opens a chat in the project (`Sessions.open/3`) and
  sends the task.
  """
  def start(%{project: nil}, _user), do: {:error, "Say which project, e.g. “in chatos-web”."}

  def start(%{action: :run, project: project}, user) do
    Routines.run(project, user)
  end

  def start(%{project: project} = parsed, user) do
    opts = [
      worktree: project.always_worktree,
      model: session_model(parsed[:use_model]),
      agent: parsed[:agent]
    ]

    with {:ok, session} <- Sessions.open(project, user, opts) do
      dir = get_in(session, ["location", "directory"]) || project.directory
      id = session["id"]

      with {:ok, _} <- Sessions.send_text(id, prompt(parsed), dir), do: {:ok, id}
    end
  end

  # "provider/id" as OpenCode takes it on a new session.
  defp session_model(%{value: value}) do
    case String.split(value, "/", parts: 2) do
      [provider, id] -> %{"providerID" => provider, "id" => id}
      _ -> nil
    end
  end

  defp session_model(_), do: nil

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

    tail = Regex.replace(~r/^\s+(project|routine|procedure)\b/i, tail, "")
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

  # "with the plan agent", "using build agent", "agent: plan". The word "agent"
  # has to be there: names like "plan" are ordinary words too.
  defp find_agent(t, agents) do
    Enum.find_value(agents, fn name ->
      a = Regex.escape(name)

      re =
        ~r/[,.]?\s*(and\s+)?((use|using|with|as|in|on)\s+)?(the\s+)?(#{a}\s+agent\b|agent\s*:?\s*#{a}(?![\w-]))/i

      case Regex.run(re, t) do
        [raw | _] -> %{name: name, raw: raw}
        nil -> nil
      end
    end)
  end

  # Model mentions: "using opus", "with gpt-5", "on sonnet 4.5 model",
  # "model: haiku". After use/using/with/on/via the name has to end the clause
  # (end, punctuation, "and", "to", "model"…), so "with flash messages" is not
  # the Flash model.
  @model_lead ~r/(?:^|[\s,;])((?:and\s+)?(?:use|using|with|on|via)\s+(?:the\s+)?|model\s*:?\s*)((?:[\w.-]+\s*){1,4})/iu
  @clause_end ~r/^(\s*$|\s*[,.;:!?]|\s+(and|then|to|for|in|model|agent|so|please)\b)/i

  defp find_model(_t, [], _default), do: nil

  defp find_model(t, models, default) do
    Regex.scan(@model_lead, t, return: :index)
    |> Enum.find_value(fn [_, {ls, ll}, {ps, pl}] ->
      model_lead? = binary_part(t, ls, ll) =~ ~r/^model/i
      # Where each word of the phrase ends; try the longest phrase first.
      ends =
        for [{s, l}] <- Regex.scan(~r/[\w.-]+/u, binary_part(t, ps, pl), return: :index),
            do: ps + s + l

      ends
      |> Enum.reverse()
      |> Enum.find_value(fn stop ->
        phrase = binary_part(t, ps, stop - ps)
        rest = binary_part(t, stop, byte_size(t) - stop)

        {model_word, rest} =
          case Regex.run(~r/^\s+model\b/i, rest) do
            [m] -> {m, binary_part(rest, byte_size(m), byte_size(rest) - byte_size(m))}
            nil -> {"", rest}
          end

        ended? = model_lead? or model_word != "" or Regex.match?(@clause_end, rest)
        model = ended? && resolve_model(phrase, models, default)
        if model, do: %{model: model, raw: binary_part(t, ls, stop - ls) <> model_word}
      end)
    end)
  end

  @doc """
  The model a phrase names ("opus", "gpt 5", "claude-sonnet-4-5", "copilot
  sonnet"), or nil. Every word has to be in the model's name, id or provider.
  On a tie: the exact name, then the default model's provider, then the newest
  (highest version in the id).
  """
  @spec resolve_model(String.t() | nil, [Catalog.model()], String.t() | nil) ::
          Catalog.model() | nil
  def resolve_model(phrase, models, default_provider \\ nil)
  def resolve_model(nil, _models, _default), do: nil

  def resolve_model(phrase, models, default_provider) do
    words = phrase |> model_words() |> Enum.reject(&(&1 in ~w(the model)))
    exact = norm(phrase)

    # One real word at least: "on 5" or "with it" names no model.
    named? = Enum.any?(words, &(String.length(&1) >= 3 or Regex.match?(~r/\d/, &1)))

    if words == [] or not named? or Enum.all?(words, &(&1 in ~w(a an it this that my new))) do
      nil
    else
      models
      |> Enum.filter(fn m ->
        tokens = model_tokens(m)
        Enum.all?(words, &(&1 in tokens))
      end)
      |> Enum.max_by(
        fn m ->
          [provider, id] = split_value(m.value)

          {norm(m.name) == exact or norm(id) == exact, provider == default_provider,
           version_key(id)}
        end,
        fn -> nil end
      )
    end
  end

  defp model_tokens(m) do
    [provider, id] = split_value(m.value)
    Enum.uniq(model_words(m.name) ++ model_words(id) ++ model_words(provider))
  end

  defp split_value(value) do
    case String.split(value, "/", parts: 2) do
      [p, id] -> [p, id]
      [id] -> ["", id]
    end
  end

  # "Claude Sonnet 4.5" → ["claude", "sonnet", "4.5", "4", "5"]: versions both
  # whole and in parts, so "4.5", "4 5" and "4-5" all match.
  defp model_words(s) do
    s
    |> String.downcase()
    |> String.split(~r/[\s\/_:()-]+/, trim: true)
    |> Enum.flat_map(fn w ->
      parts = String.split(w, ".", trim: true)
      if length(parts) > 1, do: [w | parts], else: [w]
    end)
  end

  # Ids compare by their parts, numbers as numbers: claude-sonnet-4-5 > claude-sonnet-4.
  defp version_key(id) do
    id
    |> String.split(~r/[^a-z0-9]+/i, trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> {1, n, ""}
        _ -> {0, 0, part}
      end
    end)
  end

  defp norm(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
end
