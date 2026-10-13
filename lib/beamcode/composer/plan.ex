defmodule Beamcode.Composer.Plan do
  @moduledoc """
  What the composer will do, read by the model (`Beamcode.Composer.Router`)
  and checked here against real projects, sessions and permissions before it is
  shown ("Understood as…") and carried out.

  A plan is a map with `action` and the fields that action needs:

    * `:session` / `:chat` – `project`, `task`, `skill`, `use_model`, `agent`
    * `:send` – `session` (%{id, title, project}), `text`
    * `:run` – `project` (the Operations Project), `procedure`, `inputs`
    * `:status` – `project` or nil, `status` (:latest | :overview)
    * `:create_routine` – `name`, `brief`, `connectors`
    * `:permission` – `perm`, `decision`
    * `:unclear` – `question`

  plus `summary` (the model's one-liner) and `model`.
  """
  alias Beamcode.{Composer, Connectors, Opencode, Procedures, Sessions, Workspace}
  alias Beamcode.Composer.{Catalog, Router, Status}
  alias Beamcode.Projects.Project
  alias Beamcode.Opencode.Events

  @recent 12

  ## Context

  @doc """
  What the model gets to see, and what its answer is checked against.
  `current` is `%{project: project | nil, session_id: id | nil}`.
  """
  def context(user, projects, current \\ %{}) do
    places = Enum.filter(projects, &(&1.kind == "code" or Project.chat_like?(&1)))
    routines = Enum.filter(projects, &(&1.kind == "routine"))

    inputs = Task.async(fn -> routine_inputs(routines) end)
    connectors = Task.async(fn -> connector_names() end)
    sessions = Task.async(fn -> Status.recent(places ++ routines, user) |> Enum.take(@recent) end)
    perms = Task.async(fn -> visible_perms(projects, user) end)

    %{
      projects: places,
      routines: routines,
      inputs: Task.await(inputs, 20_000),
      connectors: Task.await(connectors, 20_000),
      sessions: Task.await(sessions, 20_000),
      perms: Task.await(perms, 20_000),
      catalog: Catalog.get(),
      current: current
    }
  end

  @doc "The context as the model reads it."
  def describe(ctx) do
    current = ctx.current

    %{
      projects: Enum.map(ctx.projects, &%{name: &1.name, kind: &1.kind}),
      routines:
        Enum.map(ctx.routines, fn r ->
          %{
            name: r.name,
            procedures:
              for p <- ctx.inputs[r.name] || [] do
                %{
                  name: p.name,
                  inputs:
                    Enum.map(
                      p.inputs,
                      &%{name: &1.name, options: &1.options, multi: &1.multi, default: &1.default}
                    )
                }
              end
          }
        end),
      connectors: ctx.connectors,
      agents: catalog(ctx).agents,
      models: catalog(ctx).models |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.take(80),
      recent_sessions:
        Enum.map(ctx.sessions, fn s ->
          %{
            id: s.id,
            title: s.title,
            project: s.project.name,
            status: Status.state(s.status),
            updated: Status.ago(s.updated)
          }
        end),
      pending_permissions:
        Enum.map(ctx.perms, &%{id: &1.perm["id"], session: &1.title, asks: &1.asks}),
      current_page: %{
        project: current[:project] && current[:project].name,
        session: current[:session_id]
      }
    }
  end

  defp catalog(ctx),
    do: Map.merge(%{models: [], agents: [], default_provider: nil}, ctx[:catalog] || %{})

  defp routine_inputs(routines) do
    routines
    |> Task.async_stream(&{&1.name, Procedures.list(&1)},
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, pair} -> [pair]
      _ -> []
    end)
    |> Map.new()
  end

  defp connector_names do
    for c <- Connectors.list(), c.error == nil, do: c.name
  end

  defp visible_perms(projects, user) do
    for item <- Beamcode.Inbox.items(user, projects), item.type == :permission do
      %{
        perm: item.perm,
        title: item.session["title"] || "a session",
        asks: Beamcode.Inbox.permission_title(item.perm)
      }
    end
  end

  ## Reading the model's answer

  @doc "Asks the model and checks its answer. `{:ok, plan}` or `{:error, reason}`."
  def understand(line, ctx) do
    with {:ok, json, model} <- Router.route(line, describe(ctx)) do
      resolve(json, ctx, model)
    end
  end

  @doc "Turns the model's JSON into a plan, or says what didn't fit."
  def resolve(json, ctx, model \\ nil) do
    base = %{summary: str(json["summary"]), model: model}

    case resolve_action(json["action"], json, ctx) do
      {:ok, plan} -> {:ok, Map.merge(base, plan)}
      {:error, _} = error -> error
    end
  end

  defp resolve_action("start_session", json, ctx) do
    with {:ok, project} <- named(ctx.projects, json["project"], "project"),
         {:ok, task} <- present(json["task"], "what to do"),
         {:ok, picks} <- model_and_agent(json, ctx) do
      {:ok,
       Map.merge(
         %{action: :session, project: project, task: task, skill: blank_nil(json["skill"])},
         picks
       )}
    end
  end

  defp resolve_action("send_to_session", json, ctx) do
    id = str(json["session"])

    session =
      Enum.find(ctx.sessions, &(&1.id == id)) ||
        if(id == ctx.current[:session_id] and ctx.current[:project],
          do: %{id: id, title: "this session", project: ctx.current[:project]}
        )

    with {:ok, text} <- present(json["text"], "what to send") do
      if session,
        do: {:ok, %{action: :send, session: session, text: text}},
        else: {:error, "That session isn't one of yours I can see."}
    end
  end

  defp resolve_action("run_routine", json, ctx) do
    with {:ok, routine} <- named(ctx.routines, json["routine"], "procedure") do
      procedures = ctx.inputs[routine.name] || []

      procedure =
        Enum.find(procedures, &(&1.name == json["procedure"])) || List.first(procedures)

      known = MapSet.new((procedure && procedure.inputs) || [], & &1.name)

      inputs =
        for {k, v} <- json["inputs"] || %{}, is_binary(k), MapSet.member?(known, k), into: %{} do
          {k, v}
        end

      {:ok,
       %{action: :run, project: routine, procedure: procedure && procedure.name, inputs: inputs}}
    end
  end

  defp resolve_action("status", json, ctx) do
    status = if json["scope"] == "latest", do: :latest, else: :overview

    case str(json["project"]) do
      nil ->
        {:ok, %{action: :status, project: nil, status: status}}

      name ->
        case named(ctx.projects ++ ctx.routines, name, "project") do
          {:ok, p} ->
            {:ok, %{action: :status, project: p, status: status}}

          # Said a name we don't have: say so rather than answer about another.
          {:error, _} ->
            {:ok,
             %{action: :unclear, question: "There’s no project or procedure called “#{name}”."}}
        end
    end
  end

  defp resolve_action("create_routine", json, ctx) do
    name = kebab(json["name"])
    known = MapSet.new(ctx.connectors)

    connectors =
      for c <- List.wrap(json["connectors"]), is_binary(c), MapSet.member?(known, c), do: c

    missing =
      for(
        c <- List.wrap(json["missing"]) ++ List.wrap(json["connectors"]),
        is_binary(c),
        not MapSet.member?(known, c),
        do: c
      )
      |> Enum.uniq_by(&String.downcase/1)

    with {:ok, brief} <- present(json["brief"], "what the procedure should do") do
      if name == "",
        do: {:error, "The procedure needs a name."},
        else:
          {:ok,
           %{
             action: :create_routine,
             name: name,
             brief: brief,
             connectors: connectors,
             missing: missing
           }}
    end
  end

  defp resolve_action("permission", json, ctx) do
    decision = if json["decision"] in ~w(once always reject), do: json["decision"], else: "once"

    case Enum.find(ctx.perms, &(&1.perm["id"] == json["id"])) || one(ctx.perms) do
      nil -> {:error, "Nothing is waiting for permission."}
      p -> {:ok, %{action: :permission, perm: p, decision: decision}}
    end
  end

  defp resolve_action("chat", json, ctx) do
    with {:ok, text} <- present(json["text"], "what to ask"),
         {:ok, picks} <- model_and_agent(json, ctx) do
      case Beamcode.Composer.chat_place(ctx.projects) do
        nil ->
          {:error, "There is no Home folder yet. Name a folder to ask in."}

        project ->
          {:ok, Map.merge(%{action: :chat, project: project, task: text, skill: nil}, picks)}
      end
    end
  end

  defp resolve_action("unclear", json, _ctx),
    do: {:ok, %{action: :unclear, question: str(json["question"]) || "Say that another way?"}}

  defp resolve_action(other, _json, _ctx),
    do: {:error, "The model answered with an unknown action (#{inspect(other)})."}

  # The model and agent the person asked for, checked against what OpenCode has.
  defp model_and_agent(json, ctx) do
    %{models: models, agents: agents, default_provider: default} = catalog(ctx)

    use_model =
      case str(json["model"]) do
        nil ->
          {:ok, nil}

        name ->
          found(
            Composer.resolve_model(name, models, default),
            "No model called #{inspect(name)}."
          )
      end

    agent =
      case str(json["agent"]) do
        nil ->
          {:ok, nil}

        name ->
          found(Enum.find(agents, &(norm(&1) == norm(name))), "No agent called #{inspect(name)}.")
      end

    with {:ok, m} <- use_model, {:ok, a} <- agent, do: {:ok, %{use_model: m, agent: a}}
  end

  defp found(nil, message), do: {:error, message}
  defp found(value, _message), do: {:ok, value}

  # Exact name first, then the same with spaces/dashes ignored.
  defp named(list, name, what) do
    n = norm(name)

    case Enum.find(list, &(&1.name == name)) || Enum.find(list, &(norm(&1.name) == n)) do
      nil -> {:error, "No #{what} called #{inspect(name)}."}
      p -> {:ok, p}
    end
  end

  defp norm(nil), do: ""
  defp norm(s), do: s |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp kebab(name) do
    (name || "")
    |> to_string()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
    |> String.trim("-")
  end

  defp one([p]), do: p
  defp one(_), do: nil

  defp present(value, what) do
    case str(value) do
      nil -> {:error, "The model didn't say #{what}."}
      v -> {:ok, v}
    end
  end

  defp str(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp str(_), do: nil

  defp blank_nil(v), do: str(v)

  ## Doing it

  @doc "Read-only plans run right away; the rest wait for Enter."
  def confirm?(%{action: action}), do: action not in [:status, :unclear]

  @doc """
  Carries out a plan. Returns `{:navigate, session_id}`, `{:answer, status_answer}`,
  `{:done, message}` or `{:error, reason}`.
  """
  def execute(%{action: action} = plan, user, _projects) when action in [:session, :chat] do
    case Composer.start(plan, user) do
      {:ok, id} -> {:navigate, id}
      error -> error
    end
  end

  def execute(%{action: :send, session: s, text: text}, _user, _projects) do
    dir =
      get_in(Events.session_info(s.id) || %{}, ["location", "directory"]) || s.project.directory

    case Sessions.send_text(s.id, text, dir) do
      {:ok, _} -> {:navigate, s.id}
      error -> error
    end
  end

  def execute(%{action: :run, project: routine, inputs: inputs} = plan, user, _projects) do
    case Procedures.Runs.start(routine, user, plan[:procedure], inputs) do
      {:ok, run} -> {:navigate, run.session_id}
      error -> error
    end
  end

  def execute(%{action: :status} = plan, user, projects),
    do: {:answer, Status.answer(plan.status, plan.project, projects, user)}

  def execute(%{action: :create_routine} = plan, user, _projects) do
    attrs = %{
      "name" => plan.name,
      "kind" => "routine",
      "scope" => "team",
      "description" => plan.brief
    }

    with {:ok, project} <- Workspace.create_project(attrs, user) do
      if plan.connectors != [] do
        Enum.each(plan.connectors, &Connectors.set_granted(&1, project.name, true))
        Connectors.sync_all()
      end

      case Procedures.draft(project, user, plan.brief) do
        {:ok, session_id, _not_ready} -> {:navigate, session_id}
        error -> error
      end
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:error, Enum.map_join(cs.errors, ", ", fn {f, {m, _}} -> "#{f} #{m}" end)}

      error ->
        error
    end
  end

  def execute(%{action: :permission, perm: p, decision: decision}, _user, _projects) do
    case Opencode.reply_permission(p.perm["sessionID"], p.perm["id"], decision) do
      {:ok, _} -> {:done, decision_line(decision, p)}
      error -> error
    end
  end

  def execute(%{action: :unclear, question: q}, _user, _projects), do: {:done, q}

  defp decision_line("reject", p), do: "Denied: #{p.asks}."
  defp decision_line("always", p), do: "Allowed for good: #{p.asks}."
  defp decision_line(_, p), do: "Allowed once: #{p.asks}."

  ## Showing it

  @doc "Label/value rows for the preview."
  def rows(%{action: :session} = p),
    do:
      [{"Action", "New session"}, {"Project", p.project.name}] ++
        skill_row(p) ++ pick_rows(p) ++ [{"Task", p.task}]

  def rows(%{action: :chat} = p),
    do:
      [{"Action", "Chat"}, {"Project", p.project.name}] ++
        pick_rows(p) ++ [{"Message", p.task}]

  def rows(%{action: :send} = p),
    do: [
      {"Action", "Send to session"},
      {"Session", "#{p.session.title} · #{p.session.project.name}"},
      {"Message", p.text}
    ]

  def rows(%{action: :run} = p),
    do:
      [{"Action", "Run procedure"}, {"Procedure", "#{p.project.name} /#{p[:procedure]}"}] ++
        for({k, v} <- p.inputs, do: {k, v |> List.wrap() |> Enum.join(", ")})

  def rows(%{action: :status} = p),
    do: [
      {"Action", "Status"},
      {"Project", if(p.project, do: p.project.name, else: "All projects")}
    ]

  def rows(%{action: :create_routine} = p),
    do:
      [{"Action", "Create procedure"}, {"Name", p.name}, {"Job", p.brief}] ++
        if(p.connectors == [], do: [], else: [{"API calls", Enum.join(p.connectors, ", ")}]) ++
        missing_row(p[:missing] || [])

  def rows(%{action: :permission} = p),
    do: [
      {"Action",
       %{"once" => "Allow once", "always" => "Allow always", "reject" => "Deny"}[p.decision]},
      {"Request", "#{p.asks} · #{p.title}"}
    ]

  def rows(%{action: :unclear} = p), do: [{"Question", p.question}]

  defp missing_row([]), do: []

  defp missing_row(names),
    do: [
      {"Not connected",
       "#{Enum.join(names, ", ")}: add it in the Project’s API calls, or the procedure can’t reach it"}
    ]

  defp pick_rows(p),
    do:
      if(p[:use_model], do: [{"Model", p.use_model.name}], else: []) ++
        if(p[:agent], do: [{"Agent", p.agent}], else: [])

  defp skill_row(%{skill: nil}), do: []
  defp skill_row(%{skill: s}), do: [{"Skill", s}]

  @doc "The confirm button's label."
  def button(%{action: :run}), do: "Run"
  def button(%{action: :create_routine}), do: "Create"
  def button(%{action: :send}), do: "Send"
  def button(%{action: :permission, decision: "reject"}), do: "Deny"
  def button(%{action: :permission}), do: "Allow"
  def button(%{action: :chat}), do: "Ask"
  def button(%{action: :status}), do: "Ask again"
  def button(_), do: "Start session"
end
