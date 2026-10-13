defmodule Beamcode.Schedules do
  @moduledoc """
  A schedule is a cron line and a prompt, saved in the project's
  `schedules.json`:

      { "morning-digest": { "cron": "0 8 * * 1-5", "prompt": "/digest since the last run",
                            "scope": "team", "owner": "aksel" } }

  Optional keys: `agent`, `model` ("provider/model"), `paused` (true: kept, but
  not run), and `procedure` (which procedure a blank prompt
  runs) and `inputs`. `scope` is `team` or `me`.
  Each run is an ordinary session; runs are listed from `schedule_runs`.
  Times are server local time.
  """
  import Ecto.Query
  require Logger
  alias Beamcode.{Accounts, Opencode, Projects, Repo, Sessions}
  alias Beamcode.Schedules.{Cron, Run}

  @file_name "schedules.json"
  @summary :schedule_summary

  @doc "Short text for the sidebar, e.g. \"weekdays 08:00\". Kept in ETS by the scheduler."
  def summary(project_id) do
    case :ets.lookup(@summary, project_id) do
      [{_, text}] -> text
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def put_summary(project_id, scheds) do
    text =
      case scheds
           |> Enum.sort_by(&elem(&1, 0))
           |> Enum.map(fn {_, s} -> Cron.describe(s["cron"]) end) do
        [] -> nil
        [one] -> one
        [one | rest] -> "#{one} +#{length(rest)}"
      end

    if text,
      do: :ets.insert(@summary, {project_id, text}),
      else: :ets.delete(@summary, project_id)
  rescue
    ArgumentError -> :ok
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Beamcode.PubSub, "schedules")
  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Beamcode.PubSub, "schedules", msg)

  def read(project) do
    case Opencode.read_file(project.directory, @file_name) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) ->
            {:ok, map |> Enum.filter(fn {_, v} -> is_map(v) end) |> Map.new()}

          _ ->
            {:error, "#{@file_name} is not valid JSON"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      error ->
        error
    end
  end

  def visible?(%{"scope" => "me"} = sched, user), do: sched["owner"] == user.username
  def visible?(_sched, _user), do: true

  @doc "All schedules the user can see, across projects."
  def list_all(user) do
    Projects.list_visible(user)
    |> Task.async_stream(fn p -> {p, read(p)} end, timeout: 15_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, {p, {:ok, scheds}}} ->
        for {key, s} <- scheds, visible?(s, user), do: decorate(p, key, s)

      _ ->
        []
    end)
    |> Enum.sort_by(&{&1.project.name, &1.key})
  end

  def decorate(project, key, s) do
    now = Cron.local_now()

    next =
      case Cron.parse(s["cron"]) do
        {:ok, cron} -> if(s["paused"] != true, do: Cron.next(cron, now))
        _ -> nil
      end

    %{
      project: project,
      key: key,
      cron: s["cron"],
      prompt: s["prompt"],
      scope: s["scope"] || "team",
      owner: s["owner"],
      agent: s["agent"],
      model: s["model"],
      when: Cron.describe(s["cron"]),
      paused: s["paused"] == true,
      next: next,
      last: last_run(project.id, key),
      raw: s
    }
  end

  def save(project, key, attrs) do
    key = String.trim(key)

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, key) ->
        {:error, "Name: lowercase letters, digits and dashes"}

      not Cron.valid?(attrs["cron"]) ->
        {:error, "When: not a valid cron line"}

      String.trim(attrs["prompt"] || "") == "" and project.kind != "routine" ->
        {:error, "Prompt can't be empty"}

      true ->
        with {:ok, scheds} <- read(project) do
          entry =
            attrs
            |> Map.take(~w(cron prompt procedure scope owner agent model paused))
            |> Enum.reject(fn {_, v} -> v in [nil, "", false] end)
            |> Map.new()

          write(project, Map.put(scheds, key, entry))
        end
    end
  end

  @doc "Pauses or resumes a schedule (`paused` in schedules.json)."
  def set_paused(project, key, paused) do
    with {:ok, scheds} <- read(project) do
      case scheds[key] do
        nil ->
          {:error, "No schedule by that name."}

        s ->
          s = if paused, do: Map.put(s, "paused", true), else: Map.delete(s, "paused")
          write(project, Map.put(scheds, key, s))
      end
    end
  end

  def delete(project, key) do
    with {:ok, scheds} <- read(project), do: write(project, Map.delete(scheds, key))
  end

  defp write(project, scheds) do
    case Opencode.write_file(
           project.directory,
           @file_name,
           Jason.encode!(scheds, pretty: true) <> "\n"
         ) do
      {:ok, _} ->
        put_summary(project.id, scheds)
        broadcast({:schedules_changed, project.id})
        :ok

      error ->
        error
    end
  end

  @doc """
  Starts a scheduled run. A blank prompt runs its
  `procedure` (or its first one) with its defaults and the schedule's `inputs`.
  """
  def run(project, key, sched) do
    owner = sched["owner"] && Accounts.get_user_by_username(sched["owner"])
    scope = if sched["scope"] == "me", do: "private", else: "team"

    case String.trim(sched["prompt"] || "") do
      "" ->
        # A procedure (the one named, else the Project's first), run like any other.
        Beamcode.Procedures.Runs.start(project, owner, sched["procedure"], sched["inputs"] || %{},
          trigger: "schedule",
          key: key,
          scope: scope
        )

      prompt ->
        start_run(project, owner, prompt,
          key: key,
          procedure: procedure_of(prompt),
          scope: scope,
          agent: sched["agent"],
          model: sched["model"],
          inputs: sched["inputs"] || %{},
          # Unattended runs on a repo never touch its main checkout.
          worktree: project.kind == "code"
        )
    end
  end

  # "/refund …" ran the refund procedure.
  defp procedure_of(prompt) do
    case Regex.run(~r{^/([\w.-]+)}, prompt) do
      [_, name] -> name
      _ -> nil
    end
  end

  @doc """
  Title of a run: the schedule's name and start time, e.g. "morning-digest · Fri 9 Oct 18:09".
  Manual runs are titled "Run · <time>".
  """
  def run_title(key, time) do
    name = if key in [nil, "manual"], do: "Run", else: key
    name <> " · " <> Calendar.strftime(time, "%a %-d %b %H:%M")
  end

  @doc """
  Creates a run: a new session titled by `run_title/2` that gets `prompt`.
  opts: :key ("manual" for the Run button), :procedure, :scope, :agent, :model ("provider/id"),
  :inputs, :seen (manual runs skip the Inbox), :worktree (start in a fresh git worktree).
  """
  def start_run(project, owner, prompt, opts) do
    key = Keyword.get(opts, :key, "manual")
    scope = Keyword.get(opts, :scope, "team")

    model =
      case String.split(opts[:model] || "", "/", parts: 2) do
        [provider, id] -> %{id: id, providerID: provider}
        _ -> nil
      end

    base = %Run{
      project_id: project.id,
      schedule_key: key,
      scope: scope,
      owner_id: owner && owner.id,
      inputs: Keyword.get(opts, :inputs, %{}),
      procedure: opts[:procedure],
      seen: Keyword.get(opts, :seen, false)
    }

    session_opts = [
      scope: scope,
      schedule_key: key,
      title: run_title(key, Cron.local_now()),
      agent: opts[:agent],
      model: model,
      worktree: Keyword.get(opts, :worktree, false)
    ]

    result =
      case Sessions.start(project, owner, session_opts) do
        {:ok, session} ->
          run = Repo.insert!(%{base | session_id: session["id"]})

          case Sessions.send_text(session["id"], prompt, project.directory) do
            {:ok, _} ->
              {:ok, run}

            {:error, reason} ->
              finish(run, "failed", inspect(reason))
              {:error, reason}
          end

        {:error, reason} ->
          # No session, so record the failed attempt on its own.
          Repo.insert!(%{
            base
            | status: "failed",
              error: inspect(reason),
              finished_at: DateTime.utc_now(:second)
          })

          {:error, reason}
      end

    with {:error, reason} <- result,
         do: Logger.warning("run #{project.name}/#{key} failed to start: #{inspect(reason)}")

    broadcast({:runs_changed, project.id})
    result
  end

  @doc "All runs of a project, newest first."
  def project_runs(project_id, limit \\ 100) do
    Repo.all(
      from r in Run,
        where: r.project_id == ^project_id,
        order_by: [desc: r.inserted_at],
        limit: ^limit,
        preload: :owner
    )
  end

  @doc "One run by id (a string from the app is fine), with its owner; nil when there's none."
  def get_run(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> Repo.one(from r in Run, where: r.id == ^n, preload: :owner)
      _ -> nil
    end
  end

  @doc "The runs a run's steps started, oldest first."
  def child_runs(run_id) do
    Repo.all(
      from r in Run,
        where: r.parent_id == ^run_id,
        order_by: [asc: r.inserted_at],
        preload: :owner
    )
  end

  @doc """
  The run a session is (a schedule's own session, or a run from before
  procedures ran in chats); nil for a chat that procedure runs only pass through.
  """
  def run_for_session(session_id),
    do:
      Repo.one(
        from r in Run,
          where: r.session_id == ^session_id and is_nil(r.trigger),
          limit: 1,
          preload: :owner
      )

  @doc "The procedure runs shown in a chat (newest last), with the runs they started."
  def chat_runs(session_id, limit \\ 40) do
    top =
      Repo.all(
        from r in Run,
          where: r.session_id == ^session_id and not is_nil(r.trigger) and is_nil(r.parent_id),
          order_by: [desc: r.inserted_at],
          limit: ^limit,
          preload: :owner
      )

    ids = Enum.map(top, & &1.id)
    children = Repo.all(from r in Run, where: r.parent_id in ^ids, order_by: [asc: r.inserted_at])
    Enum.reverse(top) ++ children
  end

  def runs(project_id, key, limit \\ 10) do
    Repo.all(
      from r in Run,
        where: r.project_id == ^project_id and r.schedule_key == ^key,
        order_by: [desc: r.inserted_at],
        limit: ^limit
    )
  end

  def last_run(project_id, key), do: runs(project_id, key, 1) |> List.first()

  @doc "Each procedure's newest top-level run in a project, by name."
  def last_runs_by_procedure(project_id) do
    from(r in Run,
      where: r.project_id == ^project_id and not is_nil(r.procedure) and is_nil(r.parent_id),
      distinct: r.procedure,
      order_by: [asc: r.procedure, desc: r.inserted_at]
    )
    |> Repo.all()
    |> Map.new(&{&1.procedure, &1})
  end

  @doc "Called when a run's session stops. Saves a one-line summary of the result."
  def session_finished(session_id, status) do
    # Runs of steps move on in Beamcode.Procedures.Runs instead.
    from(r in Run,
      where:
        r.session_id == ^session_id and r.status == "running" and
          fragment("cardinality(?) = 0", r.steps)
    )
    |> Repo.all()
    |> Enum.each(fn run ->
      finish(run, status, nil, summarize(session_id))
      broadcast({:runs_changed, run.project_id})
    end)
  end

  defp finish(run, status, error, summary \\ nil) do
    run
    |> Ecto.Changeset.change(
      status: status,
      error: error,
      summary: summary,
      finished_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()
  end

  # One line for the Runs list: the result's section headings ("Urgent · 2 ·
  # Waiting · 5"), or else its first plain line.
  defp summarize(session_id) do
    case result(session_id) do
      {:ok, text} -> summary_line(text)
      _ -> nil
    end
  end

  @doc "A run's result: its session's last reply text (\"\" when there is none)."
  def result(session_id) do
    with {:ok, messages} <- Beamcode.Opencode.messages(session_id, 50) do
      text =
        messages
        |> Enum.filter(&(&1["type"] == "assistant"))
        |> Enum.flat_map(fn m ->
          for %{"type" => "text", "text" => t} <- m["content"] || [], do: t
        end)
        |> List.last()
        |> Kernel.||("")

      {:ok, text}
    end
  end

  @doc false
  def summary_line(text) do
    text = String.replace(text, ~r/```peon-status.*?(```|\z)/s, "")
    links_line(text) || headings_line(text)
  end

  # A result offering next steps as run-links: "3 × Send refund · 897 NOK".
  defp links_line(text) do
    links =
      for [_, label, query] <- Regex.scan(~r/\[([^\]]+)\]\(run:[\w.-]+\?([^)\s]*)\)/, text),
          do: {label, URI.decode_query(query)}

    case links do
      [] ->
        nil

      [{label, _} | _] ->
        same = Enum.filter(links, &(elem(&1, 0) == label))
        currencies = same |> Enum.map(&elem(&1, 1)["currency"]) |> Enum.uniq()

        amounts =
          for {_, q} <- same do
            case Float.parse(q["amount"] || "") do
              {n, ""} -> n
              _ -> nil
            end
          end

        total =
          if Enum.all?(amounts) and length(currencies) == 1 and hd(currencies),
            do: " · #{amount(Enum.sum(amounts))} #{hd(currencies)}",
            else: ""

        "#{length(same)} × #{label}#{total}"
    end
  end

  defp amount(n) when n == trunc(n), do: Integer.to_string(trunc(n))
  defp amount(n), do: :erlang.float_to_binary(n, decimals: 2)

  defp headings_line(text) do
    lines = String.split(text, "\n")
    sections = for "## " <> h <- lines, do: String.trim(h)

    clean =
      &(&1 |> String.replace(~r/^[#>*\-\s]+/, "") |> String.replace("**", "") |> String.trim())

    line =
      if length(sections) >= 2,
        do: Enum.map_join(sections, " · ", clean),
        else:
          lines
          |> Enum.reject(&String.starts_with?(&1, "#"))
          |> Enum.map(clean)
          |> Enum.find("", &(&1 != ""))

    String.slice(line, 0, 200)
  end

  @doc "Runs waiting for a person, that this user may see."
  def inbox_runs(user, projects) do
    ids = Enum.map(projects, & &1.id)

    from(r in Run,
      where: r.project_id in ^ids and r.status == "waiting" and not r.seen,
      where: r.scope == "team" or r.owner_id == ^user.id,
      order_by: [desc: r.inserted_at],
      limit: 50,
      preload: [:project, :owner]
    )
    |> Repo.all()
  end

  def mark_seen(run_id) do
    from(r in Run, where: r.id == ^run_id) |> Repo.update_all(set: [seen: true])
    broadcast({:runs_changed, nil})
  end
end
