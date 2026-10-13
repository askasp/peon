defmodule Beamcode.Procedures.Runs do
  @moduledoc """
  Runs procedures, step by step. Every start (`/name`, a button, a schedule,
  a Queue ticket, a chain's step) goes through `start/5` and is one
  `Beamcode.Schedules.Run` row, so they share one history.

  A prompt step is a message in the run's chat (`session: same`), or in a new
  child session of it (`session: fresh`) that gets a hand-over instead of the
  transcript; its model and effort are switched first. The step is done when
  its session goes idle (`session_idle/2`, from `Beamcode.Procedures.Runner`).
  Then the run moves on: back to an earlier step while a review says changes
  are needed (`on_changes`), or it waits for a person (`wait: me`) until
  `continue/2`, `back/3` or `skip/1`.

  A `run:` step starts other procedures as child runs, one per `for_each`
  item and one at a time; the step is done when the last child is. A `queue:`
  step adds tickets; a `call:` step sends one of the Project's API calls with no model.
  """
  require Logger
  import Ecto.Query, only: [from: 2]
  alias Beamcode.{Connectors, Opencode, Procedures, Projects, Repo, Sessions, TaskQueue, Tickets}
  alias Beamcode.Projects.Project
  alias Beamcode.Schedules
  alias Beamcode.Schedules.Run

  @text_limit 12_000

  ## Starting

  @doc """
  Starts `procedure` (a name or a procedure map) with `inputs`, or once per
  row when `inputs` is a list. Returns `{:ok, run}`.

  opts:
    * `:trigger` — "slash", "button", "schedule", "queue", "chain" (default "button")
    * `:session_id` — the chat to run in; else the Project's chat (a new
      worktree chat in a code Project), or for a child a session of its parent's
    * `:parent` — the run whose step started this one
    * `:ticket` — the Queue ticket it works on
    * `:key` — the schedule's name ("manual" otherwise), `:scope`
  """
  def start(%Project{} = project, user, procedure, inputs \\ %{}, opts \\ []) do
    with {:ok, proc} <- resolve(project, procedure) do
      values = inputs(proc, inputs, project)

      case done_before(project, proc, values, Keyword.get(opts, :trigger, "button")) do
        nil -> launch(project, user, proc, values, opts)
        prev -> {:ok, already_done(project, user, proc, values, prev, opts)}
      end
    end
  end

  defp launch(project, user, proc, values, opts) do
    with {:ok, sid} <- chat(project, user, proc, opts) do
      trigger = Keyword.get(opts, :trigger, "button")
      parent = opts[:parent]
      key = Keyword.get(opts, :key, "manual")

      run =
        Repo.insert!(%Run{
          project_id: project.id,
          owner_id: user && user.id,
          schedule_key: key,
          scope: Keyword.get(opts, :scope, "team"),
          session_id: sid,
          procedure: proc.name,
          trigger: trigger,
          inputs: values,
          ticket: opts[:ticket],
          parent_id: parent && parent.id,
          # Only scheduled runs come to the Inbox when they finish; a person
          # who started one is watching it.
          seen: trigger != "schedule" or parent != nil,
          steps: Enum.map(proc.steps, &%{"name" => &1.name, "status" => "pending"})
        })

      changed(run)
      {:ok, step(run, proc, 0)}
    end
  end

  # A chain or a schedule never acts twice on the same key (a charge, a
  # message): the last finished run for it, unless its steps were skipped. A
  # person starting it by hand always can.
  defp done_before(_project, %{key: nil}, _values, _trigger), do: nil

  defp done_before(project, proc, values, trigger) when trigger in ["chain", "schedule"] do
    case values[proc.key] do
      v when is_binary(v) and v != "" ->
        from(r in Run,
          where:
            r.project_id == ^project.id and r.procedure == ^proc.name and r.status == "done" and
              fragment("?->>? = ?", r.inputs, ^proc.key, ^v) and
              fragment(
                "not exists (select 1 from unnest(?) s where s->>'status' = 'skipped')",
                r.steps
              ),
          order_by: [desc: r.inserted_at],
          limit: 1
        )
        |> Repo.one()

      _ ->
        nil
    end
  end

  defp done_before(_project, _proc, _values, _trigger), do: nil

  # A run that did nothing, so the chain sees why.
  defp already_done(project, user, proc, values, prev, opts) do
    parent = opts[:parent]

    run =
      Repo.insert!(%Run{
        project_id: project.id,
        owner_id: user && user.id,
        schedule_key: Keyword.get(opts, :key, "manual"),
        scope: Keyword.get(opts, :scope, "team"),
        procedure: proc.name,
        trigger: Keyword.get(opts, :trigger, "button"),
        inputs: values,
        parent_id: parent && parent.id,
        seen: true,
        status: "done",
        summary: "Already done for #{proc.key} #{values[proc.key]} (run #{prev.id}).",
        finished_at: DateTime.utc_now(:second),
        steps: Enum.map(proc.steps, &%{"name" => &1.name, "status" => "skipped"})
      })

    changed(run)
    run
  end

  defp resolve(project, name) when is_binary(name) or is_nil(name) do
    case Procedures.find(project, name) do
      nil when name in [nil, ""] -> {:error, "This Project has no procedures yet."}
      nil -> {:error, "No procedure called #{name}."}
      p -> {:ok, p}
    end
  end

  defp resolve(_project, %{name: _} = proc), do: {:ok, proc}

  # Where the run shows: the chat it was typed in, a child session of the
  # parent's chat, its own chat in an Operations Project (see OpsChats), else
  # the Project's chat (code: a new worktree chat).
  defp chat(project, user, proc, opts) do
    cond do
      opts[:session_id] ->
        {:ok, opts[:session_id]}

      parent = opts[:parent] ->
        if needs_session?(proc),
          do: child_session(project, user, parent.session_id, proc.name, nil),
          else: {:ok, nil}

      project.kind == "routine" ->
        with {:ok, s} <-
               Sessions.start(project, user,
                 title: proc.name,
                 scope: Keyword.get(opts, :scope, "team"),
                 chat: "run",
                 procedure: proc.name,
                 schedule_key: if(opts[:trigger] == "schedule", do: opts[:key])
               ),
             do: {:ok, s["id"]}

      true ->
        title = if project.kind == "code", do: proc.name

        with {:ok, s} <-
               Sessions.open(project, user,
                 worktree: project.kind == "code",
                 title: title,
                 schedule_key: if(opts[:trigger] == "schedule", do: opts[:key])
               ),
             do: {:ok, s["id"]}
    end
  end

  defp needs_session?(proc), do: Enum.any?(proc.steps, &(&1.kind == "prompt"))

  defp child_session(project, user, parent_sid, title, model) do
    dir = session_dir(parent_sid, project)

    body =
      %{location: %{directory: dir}, title: title}
      |> then(&if(parent_sid, do: Map.put(&1, :parentID, parent_sid), else: &1))
      |> then(&if(model, do: Map.put(&1, :model, model), else: &1))

    with {:ok, s} <- Opencode.create_session(body) do
      Projects.record_session(s["id"], project, user)
      {:ok, s["id"]}
    end
  end

  # Defaults for what's missing (a row list stays as it is). A time input
  # takes `last_run` (see `since/3`) or a span back from now (`1d`).
  defp inputs(_proc, rows, _project) when is_list(rows), do: %{"rows" => rows}

  defp inputs(proc, values, project) do
    given = for {k, v} <- values || %{}, v not in [nil, ""], into: %{}, do: {k, v}

    Map.new(proc.inputs, &{&1.name, &1.default})
    |> Map.merge(given)
    |> Map.new(fn {k, v} ->
      case Enum.find(proc.inputs, &(&1.name == k)) do
        nil -> {k, v}
        input -> {k, time_value(project, proc, input, v)}
      end
    end)
  end

  defp time_value(project, proc, input, "last_run"), do: since(project, proc, input).value

  defp time_value(_project, _proc, input, v) when is_binary(v) do
    with true <- time_input?(input),
         seconds when is_integer(seconds) <- Procedures.duration(v) do
      DateTime.utc_now(:second) |> DateTime.add(-seconds) |> DateTime.to_iso8601()
    else
      _ -> v
    end
  end

  defp time_value(_project, _proc, _input, v), do: v

  defp time_input?(input), do: input.type in ~w(date datetime time) or input.default == "last_run"

  @default_max 7 * 86_400

  @doc """
  Where a `default: last_run` input starts: when this procedure's last
  finished run started, so the next run picks up where it began, but never
  more than the input's `max` back (7 days without one). A failed run
  doesn't count, so the next one covers its time again.

  `%{value, last, capped, max}`: `value` the ISO time used, `last` when the
  last good run started (nil before the first), `capped` when that was
  further back than `max`.
  """
  def since(project, proc, input, now \\ DateTime.utc_now(:second)) do
    seconds = Procedures.duration(input.max) || @default_max
    floor = DateTime.add(now, -seconds)

    last =
      from(r in Run,
        where: r.project_id == ^project.id and r.procedure == ^proc.name and r.status == "done",
        order_by: [desc: r.inserted_at],
        limit: 1,
        select: r.inserted_at
      )
      |> Repo.one()

    from = if last && DateTime.after?(last, floor), do: last, else: floor

    %{
      value: DateTime.to_iso8601(from),
      last: last && DateTime.to_iso8601(last),
      capped: last != nil and from == floor,
      max: input.max || "7d"
    }
  end

  ## Steps

  # Runs step `i`, or finishes the run after the last one.
  defp step(%Run{} = run, proc, i, opts \\ []) do
    case Enum.at(proc.steps, i) do
      nil ->
        finish(run, proc)

      s ->
        run = save(run, step: i, waiting: nil, status: "running")

        if wait_before?(project(run), s) and not Keyword.get(opts, :approved, false) do
          wait(run, proc, i, "before")
        else
          case do_step(run, proc, i, s, opts) do
            {:ok, run} -> run
            {:error, reason} -> fail(run, proc, i, reason)
          end
        end
    end
  end

  # A step that acts waits before it acts; a prompt step with a model waits
  # after, so you read what it did. A model-less prompt step (ship's Merge)
  # waits first, then runs on the last model.
  # A connector call asks first when it says `confirm:` or its tool is "ask"
  # (Peon calls it directly, so OpenCode's approval never runs).
  defp wait_before?(project, %{kind: "call"} = s),
    do: s.wait or s.confirm != nil or call_asks?(project, s)

  defp wait_before?(_project, %{kind: "run", confirm: c}) when is_binary(c), do: true
  defp wait_before?(_project, %{wait: false}), do: false
  defp wait_before?(_project, %{kind: "prompt", model: m}) when is_binary(m), do: false
  defp wait_before?(_project, _), do: true

  defp call_asks?(project, s) do
    [connector | tool] = String.split(s.call, ".")

    case Connectors.find(project, connector) do
      nil -> false
      c -> match?(%{permission: "ask"}, Connectors.find_tool(c, Enum.join(tool, ".")))
    end
  end

  defp do_step(run, proc, i, %{kind: "prompt"} = s, opts) do
    project = project(run)
    user = owner(run)
    values = values(run)

    model =
      s.model &&
        Procedures.resolve_model(s.model, s.effort, list_models(), default_provider(project))

    if s.model && model == nil,
      do: Logger.warning("procedure #{proc.name}: no model like #{s.model}")

    # The chat's own model, put back when the run ends (a step's switch would stick).
    previous =
      if model && s.session == "same" && run.session_id &&
           not Enum.any?(run.steps, & &1["previous_model"]),
         do: chat_model(run.session_id, project)

    with {:ok, sid} <- step_session(run, project, user, proc, s, model) do
      text = message(run, proc, i, s, values, opts[:note])
      dir = session_dir(sid, project)

      # A skill step goes through `/skill`; anything else is sent as written,
      # so a "/name" head line is never taken for a command.
      sent =
        if s.skill || proc.source == "legacy",
          do: Sessions.send_text(sid, text, dir),
          else: Opencode.prompt(sid, %{text: text})

      with {:ok, _} <- sent do
        {:ok,
         put_step(
           run,
           i,
           %{
             "status" => "running",
             "session_id" => sid,
             "model" => Procedures.model_label(s.model),
             "effort" => s.effort,
             "session" => s.session,
             "started" => now()
           }
           |> then(&if(previous, do: Map.put(&1, "previous_model", previous), else: &1))
         )}
      end
    end
  end

  defp do_step(run, proc, i, %{kind: "wait"}, _opts) do
    # Nothing to do once you said go.
    {:ok, done_step(run, proc, i, %{"status" => "done"}) |> elem(0)}
  end

  defp do_step(run, proc, i, %{kind: "run"} = s, opts) do
    items = opts[:items] || items(run, s)

    if items == [] and s.for_each do
      {:ok,
       done_step(run, proc, i, %{"status" => "done", "text" => "Nothing to run."}) |> elem(0)}
    else
      run =
        put_step(run, i, %{
          "status" => "running",
          "started" => now(),
          "children" => [],
          "pending" => items || [nil]
        })

      {:ok, next_child(run, proc, i)}
    end
  end

  defp do_step(run, proc, i, %{kind: "queue"} = s, opts) do
    items = opts[:items] || items(run, s) || [%{}]
    project = project(run)

    titles =
      for item <- items,
          do: Procedures.fill(s.title || "{task}", Map.merge(fill_values(run), item || %{}))

    with {:ok, ids} <-
           TaskQueue.add(project, owner(run), "main", titles, false, procedure: s.queue) do
      {:ok,
       done_step(run, proc, i, %{
         "status" => "done",
         "text" => "Queued #{length(ids)} for #{s.queue}: " <> Enum.join(ids, ", ")
       })
       |> elem(0)}
    end
  end

  defp do_step(run, proc, i, %{kind: "call"} = s, _opts) do
    project = project(run)

    with {:ok, text, data} <- call(project, s, fill_values(run)) do
      run =
        if s.returns,
          do: save(run, outputs: Map.put(run.outputs || %{}, s.returns, data)),
          else: run

      {:ok,
       done_step(run, proc, i, %{"status" => "done", "text" => text, "finished" => now()})
       |> elem(0)}
    end
  end

  # The step's session: the run's chat, or for `fresh` a new child of it with
  # the step's model. A same-session step switches the chat's model first.
  defp step_session(run, project, user, proc, %{session: "fresh"} = s, model),
    do: child_session(project, user, run.session_id, "#{proc.name} · #{s.name}", model)

  defp step_session(%Run{session_id: nil} = run, project, user, proc, _s, model) do
    with {:ok, sid} <- child_session(project, user, nil, proc.name, model) do
      save(run, session_id: sid)
      {:ok, sid}
    end
  end

  defp step_session(run, _project, _user, _proc, _s, nil), do: {:ok, run.session_id}

  defp step_session(run, _project, _user, _proc, _s, model) do
    case Opencode.switch_model(run.session_id, model) do
      {:ok, _} -> {:ok, run.session_id}
      error -> error
    end
  end

  # The step's message: `/name values` and the step's prompt, then what this
  # step must hand back (a hand-over for a fresh session, run-links to offer,
  # an output block, whether changes are needed).
  defp message(run, proc, i, s, values, note) do
    multi = length(proc.steps) > 1
    head = if multi, do: "/#{proc.name} · #{s.name} (step #{i + 1} of #{length(proc.steps)})"

    body =
      cond do
        proc.source == "legacy" and Map.has_key?(values, "rows") ->
          Procedures.batch_prompt(proc, values["rows"])

        proc.source == "legacy" ->
          Procedures.prompt(proc, values)

        multi and i > 0 ->
          prompt_only(s, Map.merge(values, run.outputs || %{}))

        multi ->
          Procedures.step_text(proc, s, values) |> String.replace(~r{^/\S+\s*}, "Inputs: ")

        true ->
          Procedures.step_text(proc, s, values)
      end

    extra = [
      s.session == "fresh" && hand_over(run, s),
      note && "A person sent this back with a note:\n\n#{note}",
      s.offers && run.parent_id == nil && offers(run, s.offers),
      s.returns && returns(proc, s.returns),
      s.on_changes && changes_rule()
    ]

    text =
      [head, body | extra]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    # A step that uses a skill runs it: `/skill` must come first.
    if s.skill && proc.source != "legacy", do: "/#{s.skill} " <> text, else: text
  end

  defp prompt_only(s, values), do: Procedures.fill(s.prompt || "Do the #{s.name} step.", values)

  # Each value filled in. A value that is only a placeholder with no value is
  # left out (an optional param); one inside text is an error, so a link never
  # goes out with "{customer.id}" in it.
  defp fill_map(map, values) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      v = to_string(v)

      case Procedures.fill_strict(v, values) do
        {:ok, text} ->
          {:cont, {:ok, Map.put(acc, k, text)}}

        error ->
          if Regex.match?(~r/^\{[\w.-]+\}$/, String.trim(v)),
            do: {:cont, {:ok, acc}},
            else: {:halt, error}
      end
    end)
  end

  # Inputs and what earlier steps returned, for `{placeholders}`.
  defp fill_values(run), do: Map.merge(run.inputs || %{}, run.outputs || %{})

  defp hand_over(run, s) do
    project = project(run)
    dir = session_dir(run.session_id, project)

    parts =
      for item <- s.hand_over do
        cond do
          step =
              Enum.find(run.steps, &(String.downcase(&1["name"] || "") == String.downcase(item))) ->
            "### What #{item} said\n\n#{step["text"] || "(nothing)"}"

          item == "ticket" and run.ticket ->
            case Tickets.raw(%{project | directory: dir}, run.ticket) do
              {:ok, raw} -> "### Ticket #{run.ticket}\n\n#{raw}"
              _ -> nil
            end

          item == "diff" ->
            "### Diff\n\n```diff\n#{diff(dir)}\n```"

          item == "transcript" ->
            "### Transcript\n\nRead it in the parent session if you need it."

          true ->
            note_file(project.directory, item)
        end
      end

    case Enum.filter(parts, &is_binary/1) do
      [] -> "You start in a fresh session."
      parts -> "You start in a fresh session. You were handed:\n\n" <> Enum.join(parts, "\n\n")
    end
  end

  # A Project note: `.peon/review.md` (or the path as written).
  defp note_file(dir, name) do
    name = if String.ends_with?(name, ".md"), do: name, else: name <> ".md"

    Enum.find_value([Path.join(".peon", name), name], fn path ->
      case Opencode.read_file(dir, path) do
        {:ok, body} -> "### #{name}\n\n#{String.slice(body, 0, @text_limit)}"
        _ -> nil
      end
    end)
  end

  defp diff(dir) do
    script =
      "base=$(git merge-base HEAD origin/HEAD 2>/dev/null || git merge-base HEAD main 2>/dev/null || git rev-parse HEAD); " <>
        "git diff --stat $base; echo; git diff $base; git ls-files --others --exclude-standard | sed 's/^/new file: /'"

    case Opencode.run_shell(dir, script, 60_000) do
      {:ok, _exit, out} -> String.slice(out, 0, 60_000)
      _ -> "(no diff)"
    end
  end

  defp offers(run, name) do
    project = project(run)

    case Procedures.find(project, name) do
      nil ->
        nil

      p ->
        fields = Enum.map(p.inputs, & &1.name)

        """
        Offer each item as a run-link that starts /#{p.name}: end its line with
        [<short label, like "Send #{p.name}">](run:#{p.name}?#{Enum.map_join(fields, "&", &"#{&1}=…")})
        with URL-encoded values#{if p.key, do: " (#{p.key} identifies the item)", else: ""}.
        """
    end
  end

  # `approved: [{ … }]` is a list of rows; `customer: { … }` is one object.
  defp returns(proc, name) do
    fields = Map.get(proc.outputs, name, [])
    shape = "{" <> Enum.map_join(fields, ", ", &~s("#{&1}": …)) <> "}"
    one = is_map(get_in(proc.front, ["outputs", name]))

    """
    End your reply with the result as JSON in a peon-output block:

    ```peon-output
    {"#{name}": #{if one, do: shape, else: "[#{shape}, …]"}}
    ```
    """
  end

  defp changes_rule do
    """
    End your reply with ```peon-step {"changes": true}``` if the work must
    change, or ```peon-step {"changes": false}``` if it's ready.
    """
  end

  ## When a step's session stops

  @doc """
  A session went idle (`:ok`) or failed/stopped. Moves on every run whose
  current step works there.
  """
  def session_idle(session_id, result) do
    from(r in Run, where: r.status == "running" and fragment("cardinality(?) > 0", r.steps))
    |> Repo.all()
    |> Enum.filter(fn run ->
      s = Enum.at(run.steps, run.step)
      s && s["status"] == "running" && s["session_id"] == session_id
    end)
    |> Enum.each(fn run ->
      with {:ok, proc} <- proc_for(run) do
        if result == :ok,
          do: step_finished(run, proc, run.step, session_id),
          else: fail(run, proc, run.step, "The step stopped.")
      end
    end)
  end

  defp step_finished(run, proc, i, sid) do
    text =
      case Schedules.result(sid) do
        {:ok, t} -> t
        _ -> ""
      end

    s = Enum.at(proc.steps, i)
    outputs = blocks(text, "peon-output") |> Enum.reduce(%{}, &Map.merge(&2, &1))
    changes = Enum.any?(blocks(text, "peon-step"), &(&1["changes"] == true))

    run = save(run, outputs: Map.merge(run.outputs || %{}, outputs))

    {run, _} =
      done_step(
        run,
        proc,
        i,
        %{
          "status" => "done",
          "text" => String.slice(strip_blocks(text), 0, @text_limit),
          "finished" => now()
        },
        false
      )

    cond do
      s.on_changes && changes ->
        loops = (Enum.at(run.steps, i)["loops"] || 0) + 1
        run = put_step(run, i, %{"loops" => loops})
        back = s.on_changes.back_to && index(proc, s.on_changes.back_to)

        if back && loops <= s.on_changes.max,
          do:
            step(run, proc, back, note: "#{s.name} asked for changes:\n\n" <> strip_blocks(text)),
          else: wait(run, proc, i, "changes")

      s.wait ->
        wait(run, proc, i, "after")

      true ->
        step(run, proc, i + 1)
    end
  end

  # Marks step `i` done with `attrs`; moves on unless `advance` is false.
  defp done_step(run, proc, i, attrs, advance \\ true) do
    run = put_step(run, i, attrs)
    if advance, do: {step(run, proc, i + 1), :advanced}, else: {run, :kept}
  end

  defp blocks(text, name) do
    for [_, body] <- Regex.scan(~r/```#{name}\s*(.*?)```/s, text),
        line <- [String.trim(body) | String.split(body, "\n")],
        {:ok, %{} = map} <- [Jason.decode(String.trim(line))],
        uniq: true,
        do: map
  end

  defp strip_blocks(text),
    do: text |> String.replace(~r/```peon-(output|step|status).*?(```|\z)/s, "") |> String.trim()

  ## Child runs (a `run:` step)

  defp next_child(run, proc, i) do
    st = Enum.at(run.steps, i)
    s = Enum.at(proc.steps, i)

    case st["pending"] || [] do
      [] ->
        results = st["results"] || []
        failed = Enum.count(results, &(&1["status"] == "failed"))

        text =
          "#{length(st["children"] || [])} run#{if(length(st["children"] || []) == 1, do: "", else: "s")}"

        text = if failed > 0, do: text <> " · #{failed} failed", else: text

        # Every child skipped (by a person, or done before): so was this step.
        status =
          cond do
            failed > 0 -> "partial"
            results != [] and Enum.all?(results, & &1["skipped"]) -> "skipped"
            true -> "done"
          end

        done_step(run, proc, i, %{
          "status" => status,
          "text" => text,
          "finished" => now()
        })
        |> elem(0)

      [item | rest] ->
        project = project(run)
        values = Map.merge(values(run), item || %{})
        fill = Map.merge(fill_values(run), item || %{})

        started =
          with {:ok, with_values} <- fill_map(s.with, fill) do
            start(project, owner(run), s.run, Map.merge(values, with_values),
              trigger: "chain",
              parent: run,
              key: run.schedule_key,
              scope: run.scope
            )
          end

        case started do
          # Done already (nothing to wait for, or done before): record it now,
          # since it finished before this step knew about it.
          {:ok, %Run{status: status} = child} when status in ["done", "failed"] ->
            run =
              run
              |> take_outputs(child)
              |> put_step(i, %{"children" => (st["children"] || []) ++ [child.id]})

            child_done(
              run,
              proc,
              i,
              %{
                "id" => child.id,
                "status" => child.status,
                "summary" => child.summary,
                "error" => child.error,
                "skipped" => skipped?(child)
              },
              rest
            )

          {:ok, child} ->
            put_step(run, i, %{
              "pending" => rest,
              "children" => (st["children"] || []) ++ [child.id]
            })

          {:error, reason} ->
            child_done(run, proc, i, %{"status" => "failed", "error" => error_text(reason)}, rest)
        end
    end
  end

  # A child run finished: its parent records it and starts the next one.
  defp child_finished(%Run{parent_id: nil}), do: :ok

  defp child_finished(%Run{parent_id: pid} = child) do
    with %Run{} = parent <- Repo.get(Run, pid),
         {:ok, proc} <- proc_for(parent),
         st when is_map(st) <- Enum.at(parent.steps, parent.step),
         true <- child.id in (st["children"] || []) do
      parent = take_outputs(parent, child)

      child_done(
        parent,
        proc,
        parent.step,
        %{
          "id" => child.id,
          "status" => child.status,
          "summary" => child.summary,
          "error" => child.error,
          "skipped" => skipped?(child)
        },
        st["pending"] || []
      )
    end
  end

  defp skipped?(run), do: Enum.any?(run.steps || [], &(&1["status"] == "skipped"))

  # The child's outputs, as "<procedure>.<name>" and "<name>".
  defp take_outputs(parent, child) do
    outputs =
      for {k, v} <- child.outputs || %{}, reduce: parent.outputs || %{} do
        acc -> acc |> Map.put("#{child.procedure}.#{k}", v) |> Map.put(k, v)
      end

    save(parent, outputs: outputs)
  end

  defp child_done(parent, proc, i, result, pending) do
    st = Enum.at(parent.steps, i)
    s = Enum.at(proc.steps, i)

    parent =
      put_step(parent, i, %{"results" => (st["results"] || []) ++ [result], "pending" => pending})

    if result["status"] == "failed" and s.on_fail != "continue",
      do: fail(parent, proc, i, "#{s.run} failed: #{result["error"] || "see its run"}"),
      else: next_child(parent, proc, i)
  end

  # The list a `for_each:` names: "email-refunds.approved" or "approved".
  defp items(_run, %{for_each: nil}), do: nil

  defp items(run, %{for_each: name}) do
    outputs = run.outputs || %{}
    list = outputs[name] || outputs[name |> String.split(".") |> List.last()]
    if is_list(list), do: Enum.map(list, &stringify/1), else: []
  end

  defp stringify(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)
  defp stringify(v), do: %{"item" => v}

  ## Waiting for a person

  defp wait(run, proc, i, kind) do
    s = Enum.at(proc.steps, i)
    items = if kind == "before", do: items(run, s)
    values = fill_values(run)

    text =
      cond do
        s.confirm ->
          Procedures.fill(s.confirm, Map.merge(values, count_total(items || [])))

        kind == "changes" ->
          "#{s.name} still asks for changes after #{s.on_changes.max} rounds."

        kind == "after" ->
          "#{s.name} is ready for you to read."

        true ->
          "#{s.name}?"
      end

    run =
      save(run,
        status: "waiting",
        seen: false,
        waiting: %{
          "step" => i,
          "kind" => kind,
          "text" => text,
          "items" => items,
          "next" => (n = Enum.at(proc.steps, i + 1)) && n.name,
          "back" => back_name(proc, i)
        }
      )

    put_step(run, i, %{"status" => if(kind == "before", do: "waiting", else: "done")})
  end

  # `{count}` and `{total}` for a confirm: "3", "897 NOK".
  defp count_total(items) do
    amounts = for item <- items, n = number(item["amount"]), do: n
    currencies = items |> Enum.map(& &1["currency"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    total =
      if amounts != [] and length(amounts) == length(items) do
        sum = Enum.sum(amounts)
        sum = if sum == trunc(sum), do: trunc(sum), else: Float.round(sum, 2)
        Enum.join([sum | currencies], " ")
      else
        ""
      end

    %{"count" => to_string(length(items)), "total" => to_string(total)}
  end

  defp number(n) when is_number(n), do: n * 1.0

  defp number(s) when is_binary(s) do
    case Float.parse(String.replace(s, ",", ".")) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp number(_), do: nil

  @doc """
  Goes on from a wait: runs a step that waited before acting (with `items`
  picked, when it acts per item), or moves past a step that waited after.
  """
  def continue(run, opts \\ [])

  def continue(%Run{status: "waiting", waiting: %{"step" => i, "kind" => kind}} = run, opts) do
    with {:ok, proc} <- proc_for(run) do
      run = save(run, seen: true)

      result =
        case kind do
          "before" ->
            items = opts[:items] && Enum.map(opts[:items], &stringify/1)
            step(run, proc, i, approved: true, items: items)

          _ ->
            step(run, proc, i + 1)
        end

      {:ok, result}
    end
  end

  def continue(_run, _opts), do: {:error, "This run isn't waiting."}

  @doc "Skips the step a run waits at and goes on with the next."
  def skip(%Run{status: "waiting", waiting: %{"step" => i}} = run) do
    with {:ok, proc} <- proc_for(run) do
      run = put_step(save(run, seen: true), i, %{"status" => "skipped"})
      {:ok, step(run, proc, i + 1)}
    end
  end

  def skip(_run), do: {:error, "This run isn't waiting."}

  @doc "Sends a waiting run back to an earlier step (`back_name/2`) with a note."
  def back(%Run{status: "waiting", waiting: %{"step" => i}} = run, note) do
    with {:ok, proc} <- proc_for(run),
         name when is_binary(name) <- back_name(proc, i),
         j when is_integer(j) <- index(proc, name) do
      {:ok, step(save(run, seen: true), proc, j, note: note, approved: true)}
    else
      nil -> {:error, "There is no step to send it back to."}
      error -> error
    end
  end

  def back(_run, _note), do: {:error, "This run isn't waiting."}

  # Where "Send back" goes: the step's `back_to`, else the step after the last
  # earlier wait (ship's Merge → Build), else the first prompt step.
  defp back_name(proc, i) do
    s = Enum.at(proc.steps, i)
    prompts = for {st, j} <- Enum.with_index(proc.steps), st.kind == "prompt", do: {st, j}

    earlier_wait =
      proc.steps
      |> Enum.take(i)
      |> Enum.with_index()
      |> Enum.filter(fn {st, _} -> st.wait end)
      |> List.last()

    cond do
      s.back_to -> s.back_to
      s.on_changes -> s.on_changes.back_to
      earlier_wait -> proc.steps |> Enum.at(elem(earlier_wait, 1) + 1) |> then(&(&1 && &1.name))
      s.kind == "prompt" -> s.name
      prompts != [] -> prompts |> hd() |> elem(0) |> Map.get(:name)
      true -> nil
    end
  end

  @doc "The run waiting in a chat, if any (typing there sends it back)."
  def waiting_in(session_id) do
    from(r in Run,
      where: r.session_id == ^session_id and r.status == "waiting",
      order_by: [desc: r.updated_at],
      limit: 1
    )
    |> Repo.one()
  end

  ## Finishing

  defp finish(run, proc) do
    failed = Enum.count(run.steps, &(&1["status"] in ["failed", "partial"]))
    last = run.steps |> Enum.reverse() |> Enum.find(&(&1["text"] not in [nil, ""]))
    summary = last && Schedules.summary_line(last["text"])

    summary =
      if failed > 0,
        do:
          "Done with #{failed} failure#{if failed == 1, do: "", else: "s"}" <>
            if(summary, do: " · " <> summary, else: ""),
        else: summary

    run =
      save(run,
        status: "done",
        waiting: nil,
        summary: summary && String.slice(summary, 0, 300),
        finished_at: DateTime.utc_now(:second)
      )

    restore_model(run)
    close_ticket(run)
    child_finished(run)
    _ = proc
    run
  end

  defp fail(run, proc, i, reason) do
    run = put_step(run, i, %{"status" => "failed", "error" => error_text(reason)})

    run =
      save(run,
        status: "failed",
        waiting: nil,
        error: "#{Enum.at(proc.steps, i).name}: #{error_text(reason)}",
        finished_at: DateTime.utc_now(:second)
      )

    restore_model(run)
    child_finished(run)
    run
  end

  defp close_ticket(%Run{ticket: nil}), do: :ok

  # The task is done: close it, and the worktree starts its next one.
  defp close_ticket(%Run{ticket: id} = run) do
    case TaskQueue.done(project(run), owner(run), run.session_id, id) do
      :ok -> :ok
      error -> Logger.warning("run #{run.id}: closing #{id} failed: #{inspect(error)}")
    end
  end

  @doc "Stops a run: interrupts its step's session and marks it failed."
  def stop(%Run{status: status} = run) when status in ["running", "waiting"] do
    st = Enum.at(run.steps, run.step)
    if st && st["session_id"], do: Opencode.interrupt(st["session_id"])

    run =
      save(run,
        status: "failed",
        waiting: nil,
        error: "Stopped.",
        finished_at: DateTime.utc_now(:second)
      )

    restore_model(run)
    child_finished(run)
    {:ok, run}
  end

  def stop(_run), do: {:error, "This run isn't going."}

  ## API calls

  @doc false
  def call(project, s, values) do
    [connector | tool] = String.split(s.call, ".")
    tool = Enum.join(tool, ".")

    with %{} = c <-
           Connectors.find(project, connector) ||
             {:error, "No #{connector} API in this Project (.peon/api/#{connector}.json)."},
         %{} = t <- Connectors.find_tool(c, tool) || {:error, "#{connector} has no #{tool}."},
         :ok <-
           if(t.permission == "deny",
             do: {:error, "#{connector} · #{tool} is denied."},
             else: :ok
           ),
         {:ok, params} <- fill_map(s.params, values) do
      {idempotency, params} = Map.pop(params, "idempotency_key")
      placeholders = for [_, p] <- Regex.scan(~r/\{(\w+)\}/, t.path), do: p
      {path_args, rest} = Map.split(params, placeholders)

      args =
        if t.method in ["GET", "DELETE"],
          do: Map.put(path_args, "query", rest),
          else: Map.put(path_args, "body", rest)

      args =
        if idempotency,
          do: Map.put(args, "headers", %{"Idempotency-Key" => idempotency}),
          else: args

      case Connectors.call(project, Connectors.tool_name(c, t), args) do
        {:ok, status, body} when status in 200..299 ->
          {:ok, call_text(status, body), decode(body)}

        {:ok, status, body} ->
          {:error, "#{status}: #{String.slice(call_note(body), 0, 300)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The step's text: "200 · ch_1", then the answer when it's JSON.
  defp call_text(status, body) do
    case Jason.decode(body) do
      {:ok, json} when is_map(json) or is_list(json) ->
        line =
          case json do
            %{} -> [json["status"], json["id"]] |> Enum.filter(&is_binary/1)
            list -> ["#{length(list)} item#{if length(list) == 1, do: "", else: "s"}"]
          end
          |> then(&Enum.join([to_string(status) | &1], " · "))

        pretty = Jason.encode!(json, pretty: true)

        pretty =
          if String.length(pretty) > 4000,
            do: String.slice(pretty, 0, 4000) <> "\n…",
            else: pretty

        line <> "\n\n```json\n" <> pretty <> "\n```"

      _ ->
        "#{status} · " <> String.slice(body, 0, 200)
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> json
      _ -> body
    end
  end

  # A short line from a JSON answer: its id and status, else the start.
  defp call_note(body) do
    case Jason.decode(body) do
      {:ok, %{} = m} ->
        [m["status"], m["id"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" · ")
        |> then(&if(&1 == "", do: String.slice(body, 0, 200), else: &1))

      _ ->
        String.slice(body, 0, 200)
    end
  end

  ## Helpers

  defp proc_for(run) do
    case Procedures.find(project(run), run.procedure) do
      nil -> {:error, "No procedure called #{run.procedure} any more."}
      p -> {:ok, p}
    end
  end

  defp index(proc, name),
    do: Enum.find_index(proc.steps, &(String.downcase(&1.name || "") == String.downcase(name)))

  defp project(run), do: Projects.get_project(run.project_id)
  defp owner(%Run{owner_id: nil}), do: nil
  defp owner(run), do: Beamcode.Accounts.get_user(run.owner_id)

  defp values(run), do: run.inputs || %{}

  defp session_dir(nil, project), do: project.directory

  # Only a code Project's chats have their own (worktree) folder.
  defp session_dir(_sid, %Project{kind: kind} = project) when kind != "code",
    do: project.directory

  defp session_dir(sid, project) do
    case Opencode.get_session(sid) do
      {:ok, %{} = session} -> Sessions.session_dir(session, project)
      _ -> project.directory
    end
  end

  defp chat_model(sid, project) do
    case Opencode.get_session(sid) do
      {:ok, %{"model" => %{"id" => _, "providerID" => _} = m}} ->
        m
        |> Map.take(["id", "providerID", "variant"])
        |> Map.reject(&(elem(&1, 1) in [nil, "default"]))

      _ ->
        case Opencode.default_model(project.directory) do
          {:ok, %{"id" => id, "providerID" => p}} -> %{"id" => id, "providerID" => p}
          _ -> nil
        end
    end
  end

  # Puts the chat's model back once the run is over.
  defp restore_model(run) do
    case Enum.find_value(run.steps, & &1["previous_model"]) do
      nil -> :ok
      model -> Opencode.switch_model(run.session_id, model)
    end
  end

  # Short model names prefer the provider the Project's default model is from.
  defp default_provider(project) do
    case Opencode.default_model(project.directory) do
      {:ok, %{"providerID" => p}} -> p
      _ -> nil
    end
  end

  defp list_models do
    case Opencode.models() do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp put_step(run, i, attrs) do
    steps = List.update_at(run.steps, i, &Map.merge(&1, attrs))
    save(run, steps: steps)
  end

  defp save(run, attrs) do
    run = run |> Ecto.Changeset.change(attrs) |> Repo.update!()
    changed(run)
    run
  end

  defp changed(run),
    do: Phoenix.PubSub.broadcast(Beamcode.PubSub, "schedules", {:runs_changed, run.project_id})

  defp now, do: DateTime.utc_now(:second) |> DateTime.to_iso8601()

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
