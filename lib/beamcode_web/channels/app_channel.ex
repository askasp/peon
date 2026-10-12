defmodule BeamcodeWeb.AppChannel do
  @moduledoc """
  The phone app's "app" channel: lists, the inbox and the composer.

  Requests (each replies; slow ones answer from a task):

    * `projects` `{stats?}` → `{projects}`; with `stats`, each has `sessions` and `updated`
    * `sessions` `{project_id}` → `{sessions}`
    * `running` → `{sessions}` running or waiting now
    * `inbox` → `{items}`
    * `permission` `{session_id, id, decision}` → `{}` (decision: once | always | reject)
    * `dismiss_run` `{id}` → `{}`
    * `new_session` `{project_id, text?, worktree?, branch?}` → `{session_id}`; `branch`
      continues that branch in its worktree (made when it has none)
    * `routine` `{project_id}` → `{project, runs}`
    * `run_routine` `{project_id}` → `{session_id}`
    * `schedules` → `{schedules}`
    * `change_password` `{password}` → `{token}`; tokens from before stop working
    * `save_keys` `{prefs?, binds?}` → `{keys}`: keymap preferences and in-session shortcuts
    * `new_project_options` → `{known_repos, known_routines, connectors}` for the new-project form
    * `create_project` `{params}` → `{project_id, session_id?, note?}`; a new routine opens a
      session that drafts its instructions (`session_id`); a Dataset with
      `source: {connector, choice}` is synced from that service
    * `source_connectors` → `{connectors}`; `source_choices` `{connector}` → `{account, choices}`
      (projects, inboxes); `source_connect` `{connector, token}` → `{account}` (admins)
    * `compose:preview` `{text}` → `{preview}`: the rule reading, while typing or talking
    * `compose:submit` `{text}` → `{plan}` to confirm, or `{result}` when it was done right away
    * `compose:confirm` → `{result}`, carrying out the last plan

  A composer `result` is `{kind: "navigate", session_id, spoken}`,
  `{kind: "answer", text, spoken, open, items}` or `{kind: "done", message, spoken}`.

  Pushes: `activity` `{type, session_id, status}` for every session status change,
  then (debounced) `inbox` `{items}` and `running` `{sessions}`; `projects` when
  projects change; `runs_changed` when a run starts, ends or is dismissed;
  `schedules_changed` when someone edits a schedule.
  """
  use BeamcodeWeb, :channel

  alias Beamcode.{
    Composer,
    Connectors,
    DataSources,
    Inbox,
    Keybinds,
    Opencode,
    Projects,
    ProjectTools,
    Procedures,
    Schedules,
    Sessions,
    Vault,
    Workspace
  }

  alias Beamcode.Composer.{Catalog, Plan}
  alias Beamcode.Procedures.Runs
  alias Beamcode.Opencode.Events
  alias BeamcodeWeb.{AppJSON, AppToken, ChannelTasks}

  @refresh_after 400
  @decisions ~w(once always reject)

  @impl true
  def join("app", _params, %{assigns: %{user: nil}}), do: {:error, %{reason: "unauthorized"}}

  def join("app", _params, socket) do
    Events.subscribe_activity()
    Projects.subscribe()
    Schedules.subscribe()

    user = socket.assigns.user
    projects = Projects.list_visible(user)
    send(self(), :refresh)

    # Home shows up in the projects push once it exists.
    if Application.get_env(:beamcode, :ensure_home, true) and
         not Enum.any?(projects, &(&1.kind == "home" and &1.owner_id == user.id)),
       do:
         Task.Supervisor.start_child(Beamcode.TaskSupervisor, fn ->
           Workspace.ensure_home(user)
         end)

    {:ok,
     %{
       user: AppJSON.user(user),
       projects: Enum.map(projects, &AppJSON.project/1),
       keys: keys(user)
     }, assign(socket, refresh_ref: nil, plan: nil, tasks: %{})}
  end

  ## Requests

  @impl true
  def handle_in("projects", params, socket) do
    user = socket.assigns.user
    stats? = params["stats"] == true

    ChannelTasks.reply_async(socket, fn ->
      projects = Projects.list_visible(user)
      {:ok, %{projects: Enum.map(projects, &project_with_stats(&1, user, stats?))}}
    end)
  end

  def handle_in("sessions", %{"project_id" => id}, socket) do
    user = socket.assigns.user

    with_project(socket, id, fn project ->
      ChannelTasks.reply_async(socket, fn ->
        case Sessions.list_visible(project, user) do
          {:ok, sessions} ->
            sessions = Enum.sort_by(sessions, &(get_in(&1, ["time", "updated"]) || 0), :desc)

            {:ok,
             %{
               project: AppJSON.project(project),
               sessions: Enum.map(sessions, &AppJSON.listed_session(&1, project))
             }}

          {:error, reason} ->
            error(reason)
        end
      end)
    end)
  end

  def handle_in("running", _params, socket),
    do: {:reply, {:ok, %{sessions: running(socket)}}, socket}

  def handle_in("inbox", _params, socket), do: {:reply, {:ok, %{items: inbox(socket)}}, socket}

  def handle_in("permission", %{"session_id" => sid, "id" => id, "decision" => decision}, socket)
      when decision in @decisions do
    user = socket.assigns.user

    ChannelTasks.reply_async(socket, fn ->
      with {:ok, _session, _project, _record} <- Sessions.fetch_visible(sid, user),
           {:ok, _} <- Opencode.reply_permission(sid, id, decision) do
        {:ok, %{}}
      else
        :error -> {:error, %{message: "Session not found, or not yours to see."}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("dismiss_run", %{"id" => id}, socket) do
    user = socket.assigns.user

    if Enum.any?(Schedules.inbox_runs(user, Projects.list_visible(user)), &(&1.id == id)) do
      Schedules.mark_seen(id)
      {:reply, {:ok, %{}}, socket}
    else
      {:reply, {:error, %{message: "Run not found."}}, socket}
    end
  end

  def handle_in("new_session", %{"project_id" => id} = params, socket) do
    user = socket.assigns.user
    text = String.trim(params["text"] || "")

    with_project(socket, id, fn project ->
      worktree =
        if is_boolean(params["worktree"]), do: params["worktree"], else: project.always_worktree

      ChannelTasks.reply_async(socket, fn ->
        with {:ok, session} <-
               Sessions.open(project, user, worktree: worktree, branch: params["branch"]),
             {:ok, _} <- send_first(session, project, text) do
          {:ok, %{session_id: session["id"]}}
        else
          {:error, reason} -> error(reason)
        end
      end)
    end)
  end

  def handle_in("routine", %{"project_id" => id}, socket) do
    user = socket.assigns.user

    with_project(socket, id, fn project ->
      runs =
        project.id
        |> Schedules.project_runs(30)
        |> Enum.filter(&(&1.scope == "team" or &1.owner_id == user.id))

      {:reply, {:ok, %{project: AppJSON.project(project), runs: Enum.map(runs, &AppJSON.run/1)}},
       socket}
    end)
  end

  def handle_in("run_routine", %{"project_id" => id}, socket) do
    user = socket.assigns.user

    with_project(socket, id, fn project ->
      ChannelTasks.reply_async(socket, fn ->
        case Runs.start(project, user, nil) do
          {:ok, run} -> {:ok, %{session_id: run.session_id}}
          {:error, reason} -> error(reason)
        end
      end)
    end)
  end

  def handle_in("schedules", _params, socket) do
    user = socket.assigns.user

    ChannelTasks.reply_async(socket, fn ->
      {:ok, %{schedules: Enum.map(Schedules.list_all(user), &AppJSON.schedule/1)}}
    end)
  end

  def handle_in("pause_schedule", %{"project_id" => id, "key" => key, "paused" => paused}, socket)
      when is_binary(key) and is_boolean(paused) do
    user = socket.assigns.user

    with_project(socket, id, fn project ->
      ChannelTasks.reply_async(socket, fn ->
        case ProjectTools.pause_schedule(project, key, paused, user) do
          :ok -> {:ok, %{}}
          {:error, msg} -> {:error, %{message: msg}}
        end
      end)
    end)
  end

  def handle_in("change_password", %{"password" => password}, socket) when is_binary(password) do
    case Beamcode.Accounts.update_password(socket.assigns.user, %{"password" => password}) do
      {:ok, user} ->
        # Tokens from before stop working: this device gets a new one, then
        # every open socket (other devices too) is closed and must reconnect.
        send(self(), :password_changed)
        {:reply, {:ok, %{token: AppToken.sign(user)}}, assign(socket, user: user)}

      {:error, cs} ->
        {:reply,
         {:error, %{message: Enum.map_join(cs.errors, ", ", fn {f, {m, _}} -> "#{f} #{m}" end)}},
         socket}
    end
  end

  def handle_in("save_keys", params, socket) do
    user = socket.assigns.user

    prefs =
      if is_map(params["prefs"]),
        do: Keybinds.pref_overrides(Map.merge(Keybinds.prefs(user), params["prefs"])),
        else: Keybinds.pref_overrides(Keybinds.prefs(user))

    binds =
      if is_map(params["binds"]),
        do: Keybinds.overrides(params["binds"]),
        else: Keybinds.overrides(Keybinds.merged(user))

    {:ok, user} = Beamcode.Accounts.update_keybinds(user, Map.merge(prefs, binds))
    {:reply, {:ok, %{keys: keys(user)}}, assign(socket, user: user)}
  end

  def handle_in("new_project_options", _params, socket) do
    ChannelTasks.reply_async(socket, fn ->
      secrets = Vault.names()

      {:ok,
       %{
         known_repos: Workspace.known_repos(),
         known_routines: Workspace.unregistered_routines(),
         connectors:
           for c <- Connectors.list(), c.error == nil do
             %{name: c.name, tools: length(c.tools), ready: Connectors.ready?(c, secrets)}
           end
       }}
    end)
  end

  def handle_in("source_connectors", _params, socket),
    do: {:reply, {:ok, %{connectors: DataSources.connector_list()}}, socket}

  def handle_in("source_choices", %{"connector" => id}, socket) when is_binary(id) do
    ChannelTasks.reply_async(socket, fn ->
      case DataSources.choices(id) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("source_connect", %{"connector" => id, "token" => token}, socket)
      when is_binary(id) and is_binary(token) do
    user = socket.assigns.user

    if user.admin do
      ChannelTasks.reply_async(socket, fn ->
        case DataSources.connect(id, token, user) do
          {:ok, account} -> {:ok, %{account: account}}
          {:error, reason} -> error(reason)
        end
      end)
    else
      {:reply, {:error, %{message: "An admin connects services (Settings → Connectors)."}},
       socket}
    end
  end

  # Only these can be made from the app; "system" projects (setup) get every connector.
  @creatable ~w(code routine chat document design dataset)

  def handle_in("create_project", %{"params" => %{"kind" => kind}}, socket)
      when kind not in @creatable,
      do: {:reply, {:error, %{message: "Pick a template."}}, socket}

  def handle_in("create_project", %{"params" => raw}, socket) when is_map(raw) do
    user = socket.assigns.user
    granted = for name <- List.wrap(raw["connectors"]), is_binary(name), do: name

    params =
      Map.take(raw, ~w(kind name source github_token always_worktree scope description import))

    # A Dataset's source is a connector, not a repository.
    params =
      if raw["kind"] == "dataset",
        do: Map.put(params, "source", if(is_map(raw["source"]), do: raw["source"])),
        else: params

    ChannelTasks.reply_async(socket, fn -> create_project(params, granted, user) end)
  end

  def handle_in("compose:preview", %{"text" => text}, socket) when is_binary(text) do
    parsed = Composer.parse(text, projects(socket), Catalog.get())
    {:reply, {:ok, %{preview: preview(parsed)}}, socket}
  end

  def handle_in("compose:submit", %{"text" => text} = params, socket) when is_binary(text) do
    user = socket.assigns.user
    projects = projects(socket)

    case Composer.parse(text, projects, Catalog.get()) do
      nil ->
        {:reply, {:error, %{message: "Say or type what to do."}}, socket}

      # Sure of the action but not where: ask. Unsure lines go to the model, which
      # also knows the page you're on ("here").
      %{sure: true, project: nil, action: action} when action in [:session, :chat] ->
        {:reply, {:error, %{message: "Say which project, e.g. “in chatos-web”."}}, socket}

      %{sure: true} = parsed ->
        execute(assign(socket, plan: nil), rules_plan(parsed))

      _ ->
        ChannelTasks.reply_async(
          socket,
          fn ->
            understand(text, user, projects, current_page(params["current"], projects, user))
          end,
          &keep_plan/2
        )
    end
  end

  def handle_in("compose:confirm", _params, %{assigns: %{plan: nil}} = socket),
    do: {:reply, {:error, %{message: "Nothing to confirm."}}, socket}

  def handle_in("compose:confirm", _params, socket),
    do: execute(assign(socket, plan: nil), socket.assigns.plan)

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{message: "Unknown request."}}, socket}

  ## Pushes

  @impl true
  def handle_info({:oc_activity, type, data}, socket) do
    sid = data["sessionID"]

    if sid,
      do: push(socket, "activity", %{type: type, session_id: sid, status: Events.status(sid)})

    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:password_changed, socket) do
    AppToken.disconnect(socket.assigns.user.id)
    {:noreply, socket}
  end

  def handle_info({:project_changed, _}, socket) do
    push(socket, "projects", %{projects: Enum.map(projects(socket), &AppJSON.project/1)})
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:schedules_changed, _}, socket) do
    push(socket, "schedules_changed", %{})
    {:noreply, socket}
  end

  def handle_info({:runs_changed, _}, socket) do
    push(socket, "runs_changed", %{})
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:refresh, socket) do
    push(socket, "inbox", %{items: inbox(socket)})
    push(socket, "running", %{sessions: running(socket)})
    {:noreply, assign(socket, refresh_ref: nil)}
  end

  def handle_info({ref, _} = msg, socket) when is_reference(ref),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info({:DOWN, _, :process, _, _} = msg, socket),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  defp projects(socket), do: Projects.list_visible(socket.assigns.user)

  defp with_project(socket, id, fun) do
    case Enum.find(projects(socket), &(to_string(&1.id) == to_string(id))) do
      nil -> {:reply, {:error, %{message: "Project not found."}}, socket}
      project -> fun.(project)
    end
  end

  defp schedule_refresh(%{assigns: %{refresh_ref: nil}} = socket),
    do: assign(socket, refresh_ref: Process.send_after(self(), :refresh, @refresh_after))

  defp schedule_refresh(socket), do: socket

  defp inbox(socket) do
    user = socket.assigns.user
    Inbox.items(user, projects(socket)) |> Enum.map(&AppJSON.inbox_item/1)
  end

  defp running(socket),
    do: Sessions.running(socket.assigns.user, projects(socket)) |> Enum.map(&AppJSON.running/1)

  defp project_with_stats(project, _user, false), do: AppJSON.project(project)

  defp project_with_stats(project, user, true) do
    stats =
      case Sessions.list_visible(project, user) do
        {:ok, sessions} ->
          %{
            sessions: length(sessions),
            updated:
              sessions
              |> Enum.map(&(get_in(&1, ["time", "updated"]) || 0))
              |> Enum.max(fn -> nil end)
          }

        _ ->
          %{sessions: nil, updated: nil}
      end

    Map.merge(AppJSON.project(project), stats)
  end

  defp send_first(_session, _project, ""), do: {:ok, nil}

  defp send_first(session, project, text),
    do: Sessions.send_text(session["id"], text, Sessions.session_dir(session, project))

  defp error(reason), do: {:error, %{message: ChannelTasks.error_message(reason)}}

  ## Keys

  # Everything the app's keyboard handling and its help overlay need.
  defp keys(user) do
    prefs = Keybinds.prefs(user)
    binds = Keybinds.merged(user)

    %{
      prefs: prefs,
      binds: binds,
      actions:
        for(
          {action, default, desc} <- Keybinds.list(),
          do: %{action: action, default: default, desc: desc}
        ),
      globals: Keybinds.globals(user),
      help:
        for {title, rows} <- Keybinds.help(prefs, user, binds) do
          %{title: title, rows: for({keys, label} <- rows, do: %{keys: keys, label: label})}
        end
    }
  end

  ## New projects

  defp create_project(
         %{"kind" => "dataset", "source" => %{"connector" => id} = source} = params,
         _granted,
         user
       ) do
    case create_project(Map.delete(params, "source"), [], user) do
      {:ok, %{project_id: project_id} = reply} ->
        project = Projects.get_project(project_id)

        note =
          with {:ok, name} <- DataSources.add(project, id, source["choice"]),
               :ok <- DataSources.refresh(project, name) do
            nil
          else
            {:error, reason} ->
              "Created, but the first sync failed: #{ChannelTasks.error_message(reason)}"
          end

        {:ok, if(note, do: Map.put(reply, :note, note), else: reply)}

      error ->
        error
    end
  end

  defp create_project(params, granted, user) do
    params = if params["kind"] == "dataset", do: Map.delete(params, "source"), else: params

    case Workspace.create_project(params, user) do
      {:ok, project} ->
        if project.kind == "routine" and granted != [] do
          Enum.each(granted, &Connectors.set_granted(&1, project.name, true))
          Connectors.sync_all()
        end

        # A described Procedure Folder starts by drafting its first procedure.
        if project.kind == "routine" and params["import"] != "true" and
             String.trim(params["description"] || "") != "" do
          case Procedures.draft(project, user, params["description"] || "", granted) do
            {:ok, session_id, []} ->
              {:ok, %{project_id: project.id, session_id: session_id}}

            {:ok, session_id, not_ready} ->
              note = "#{Enum.join(not_ready, ", ")} needs its secret. Set it on Connectors."
              {:ok, %{project_id: project.id, session_id: session_id, note: note}}

            {:error, reason} ->
              note =
                "Created, but drafting its procedure failed: #{ChannelTasks.error_message(reason)}"

              {:ok, %{project_id: project.id, note: note}}
          end
        else
          {:ok, %{project_id: project.id}}
        end

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, %{message: Enum.map_join(cs.errors, ", ", fn {f, {m, _}} -> "#{f} #{m}" end)}}

      {:error, reason} ->
        error(reason)
    end
  end

  ## Composer

  # Same as the web composer: a sure rule reading runs without asking the model.
  defp rules_plan(%{action: :run} = parsed),
    do: %{action: :run, project: parsed.project, inputs: %{}, summary: nil, model: nil}

  defp rules_plan(parsed), do: Map.merge(parsed, %{summary: nil, model: nil})

  defp preview(nil), do: nil

  defp preview(parsed) do
    rows =
      [{"Action", Composer.action_label(parsed.action)}] ++
        if(parsed.project, do: [{"Project", parsed.project.name}], else: []) ++
        if(parsed.skill, do: [{"Skill", parsed.skill}], else: []) ++
        if(parsed.use_model, do: [{"Model", parsed.use_model.name}], else: []) ++
        if(parsed.agent, do: [{"Agent", parsed.agent}], else: []) ++
        if(parsed.task not in [nil, ""], do: [{"Task", parsed.task}], else: [])

    %{
      action: to_string(parsed.action),
      rows: Enum.map(rows, &Tuple.to_list/1),
      sure: parsed.sure,
      button: Composer.button_label(parsed.action)
    }
  end

  # Read-only plans (status) run at once; the rest wait for compose:confirm.
  # The page the user is on, so "new session here" and "send this to this
  # session" work. Only a project and session the user can see.
  defp current_page(%{"project_id" => pid} = current, projects, user) do
    case Enum.find(projects, &(&1.id == pid)) do
      nil ->
        %{}

      project ->
        sid = current["session_id"]

        visible? =
          is_binary(sid) and
            match?({:ok, _, %{id: ^pid}, _}, Sessions.fetch_visible(sid, user))

        if visible?,
          do: %{project: project, session_id: sid},
          else: %{project: project, session_id: nil}
    end
  end

  defp current_page(_, _, _), do: %{}

  defp understand(text, user, projects, current) do
    case Plan.understand(text, Plan.context(user, projects, current)) do
      {:ok, plan} ->
        if Plan.confirm?(plan),
          do: {:plan, plan},
          else: result(Plan.execute(plan, user, projects), plan)

      {:error, reason} ->
        error(reason)
    end
  end

  defp keep_plan({:plan, plan}, socket),
    do: {{:ok, %{plan: plan_json(plan)}}, assign(socket, plan: plan)}

  defp keep_plan(reply, socket), do: {reply, socket}

  defp execute(socket, plan) do
    user = socket.assigns.user
    projects = projects(socket)
    ChannelTasks.reply_async(socket, fn -> result(Plan.execute(plan, user, projects), plan) end)
  end

  defp plan_json(plan) do
    %{
      action: to_string(plan.action),
      summary: plan.summary,
      rows: Enum.map(Plan.rows(plan), &Tuple.to_list/1),
      button: Plan.button(plan)
    }
  end

  defp result({:navigate, session_id}, plan),
    do: {:ok, %{result: %{kind: "navigate", session_id: session_id, spoken: started_line(plan)}}}

  defp result({:answer, answer}, _plan) do
    {:ok,
     %{
       result: %{
         kind: "answer",
         text: answer.text,
         reply: answer.reply,
         spoken: answer.spoken,
         open: answer.open,
         items:
           Enum.map(answer.items, fn s ->
             %{
               id: s.id,
               title: s.title,
               status: s.status,
               updated: s.updated,
               project: s.project.name
             }
           end)
       }
     }}
  end

  defp result({:done, message}, _plan),
    do: {:ok, %{result: %{kind: "done", message: message, spoken: message}}}

  defp result({:error, reason}, _plan), do: error(reason)

  defp started_line(%{action: :run, project: p}), do: "Running #{spoken(p.name)}."
  defp started_line(%{action: :send, session: s}), do: "Sent to #{spoken(s.title)}."
  defp started_line(%{action: :create_routine, name: name}), do: "Created #{spoken(name)}."

  defp started_line(%{project: %{name: name}} = plan),
    do: "Started in #{spoken(name)}#{if plan[:skill], do: " with #{spoken(plan.skill)}"}."

  defp started_line(_), do: "Started."

  defp spoken(name), do: String.replace(name || "", ~r/[-_]+/, " ")
end
