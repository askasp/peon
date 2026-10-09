defmodule BeamcodeWeb.ProjectLive do
  @moduledoc "A project: its sessions, skills (and AGENTS.md instructions), schedules and settings."
  use BeamcodeWeb, :live_view
  alias Beamcode.{Connectors, GitTokens, Opencode, Projects, Routines, Schedules, Vault}
  alias Beamcode.Opencode.Events
  alias Beamcode.Schedules.Cron
  alias BeamcodeWeb.Shell

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_visible!(id, socket.assigns.current_scope.user)

    {:ok,
     socket
     |> Shell.set_current(project)
     |> assign(project: project, page_title: project.name, query: "", sessions: [], loaded: false)
     |> assign(worktree: project.always_worktree, refresh_ref: nil)
     |> assign(routine: nil, run_menu: nil, runs: [])
     |> stream(:groups, [])
     |> stream(:run_groups, [])
     |> then(fn s ->
       if project.kind == "routine",
         do: start_async(s, :routine, fn -> Routines.config(project) end),
         else: s
     end)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_tab(socket, socket.assigns.live_action)}
  end

  defp load_tab(socket, :sessions) do
    if routine?(socket), do: load_runs(socket), else: load_sessions(socket)
  end

  defp load_tab(socket, :chats), do: load_sessions(socket)

  defp load_tab(socket, :skills) do
    socket
    |> assign(skills: skill_files(socket.assigns.project), new_skill: nil)
    |> open_file(socket.assigns[:file_path] || "AGENTS.md")
  end

  defp load_tab(socket, :schedules) do
    project = socket.assigns.project
    user = socket.assigns.current_scope.user

    {schedules, error} =
      case Schedules.read(project) do
        {:ok, map} ->
          {for(
             {k, s} <- Enum.sort(map),
             Schedules.visible?(s, user),
             do: Schedules.decorate(project, k, s)
           ), nil}

        {:error, e} ->
          {[], Shell.format_error(e)}
      end

    socket
    |> assign(schedules: schedules, schedules_error: error, editing: nil)
    |> assign(agents: list_agents(project), models: list_models())
    |> assign_schedule_form(new_schedule_params(user))
  end

  defp load_tab(socket, :settings) do
    project = socket.assigns.project

    {connectors, secrets} =
      if Beamcode.Workspace.uses_gateway?(project) and project.kind != "system",
        do: {Connectors.list() |> Enum.filter(&(&1.error == nil)), Vault.names()},
        else: {[], MapSet.new()}

    socket
    |> assign(connectors: connectors, secrets: secrets)
    |> assign(github_hint: if(project.kind == "code", do: GitTokens.hint(project)))
    |> assign(github_form: to_form(%{"token" => ""}, as: :github), github_error: nil)
    |> assign(github_saving: false)
    |> assign(
      :settings_form,
      to_form(
        %{"scope" => project.scope, "always_worktree" => to_string(project.always_worktree)},
        as: :settings
      )
    )
  end

  defp routine?(socket), do: socket.assigns.project.kind == "routine"

  ## Runs (routines)

  defp load_runs(socket) do
    runs = Schedules.project_runs(socket.assigns.project.id)
    socket |> assign(runs: runs, loaded: true, load_error: nil) |> stream_runs()
  end

  defp stream_runs(socket) do
    q = String.downcase(socket.assigns.query)
    user = socket.assigns.current_scope.user

    groups =
      socket.assigns.runs
      |> Enum.filter(&(&1.scope == "team" or &1.owner_id == user.id))
      |> Enum.filter(
        &(q == "" or
            String.contains?(
              String.downcase("#{&1.summary} #{&1.error} #{inputs_label(&1.inputs)}"),
              q
            ))
      )
      |> Enum.chunk_by(&day_label(DateTime.to_unix(&1.inserted_at, :millisecond)))
      |> Enum.map(fn [first | _] = runs ->
        label = day_label(DateTime.to_unix(first.inserted_at, :millisecond))
        %{id: "runs-" <> label, label: label, runs: runs}
      end)

    socket
    |> assign(:empty?, groups == [])
    |> stream(:run_groups, groups, reset: true)
  end

  def inputs_label(inputs) when is_map(inputs) and map_size(inputs) > 0 do
    inputs
    |> Enum.sort()
    |> Enum.map_join(" · ", fn
      {_, list} when is_list(list) -> Enum.join(list, ", ")
      {_, v} -> to_string(v)
    end)
  end

  def inputs_label(_), do: nil

  def run_title(run), do: Schedules.run_title(run.schedule_key, local(run.inserted_at))

  def run_who(run, user) do
    cond do
      run.schedule_key != "manual" -> "schedule"
      run.owner_id == user.id -> "you"
      run.owner -> run.owner.username
      true -> "someone"
    end
  end

  def run_duration(%{finished_at: nil}), do: nil

  def run_duration(run) do
    s = DateTime.diff(run.finished_at, run.inserted_at)
    if s < 60, do: "#{s}s", else: "#{div(s, 60)}m #{rem(s, 60)}s"
  end

  ## Sessions

  defp load_sessions(socket) do
    project = socket.assigns.project
    user = socket.assigns.current_scope.user

    params =
      if project.oc_project_id,
        do: [project: project.oc_project_id, limit: 150],
        else: [directory: project.directory, limit: 150]

    case Opencode.list_sessions(params) do
      {:ok, sessions} ->
        sessions =
          Enum.reject(sessions, &(&1["parentID"] || get_in(&1, ["time", "archived"])))

        records = Projects.session_records(Enum.map(sessions, & &1["id"]))

        sessions =
          sessions
          |> Enum.filter(&Projects.session_visible?(records[&1["id"]], user))
          # On a routine, runs live in the Runs tab; Chats are about the routine itself.
          |> Enum.reject(
            &((routine?(socket) and records[&1["id"]]) && records[&1["id"]].schedule_key)
          )
          |> Enum.map(&Map.put(&1, "record", records[&1["id"]]))

        socket |> assign(sessions: sessions, loaded: true, load_error: nil) |> stream_groups()

      {:error, reason} ->
        socket
        |> assign(loaded: true, load_error: Shell.format_error(reason))
        |> stream(:groups, [], reset: true)
    end
  end

  defp stream_groups(socket) do
    q = String.downcase(socket.assigns.query)

    groups =
      socket.assigns.sessions
      |> Enum.filter(&(q == "" or String.contains?(String.downcase(&1["title"] || ""), q)))
      |> Enum.sort_by(&get_in(&1, ["time", "updated"]), :desc)
      |> Enum.group_by(&day_label(get_in(&1, ["time", "updated"])))
      |> Enum.sort_by(fn {_, [s | _]} -> -get_in(s, ["time", "updated"]) end)
      |> Enum.map(fn {label, sessions} ->
        %{id: "day-" <> label, label: label, sessions: sessions}
      end)

    socket
    |> assign(:empty?, groups == [])
    |> stream(:groups, groups, reset: true)
  end

  defp to_local(ms) do
    ms
    |> div(1000)
    |> DateTime.from_unix!()
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  defp day_label(ms) do
    date = to_local(ms) |> NaiveDateTime.to_date()
    today = Cron.local_now() |> NaiveDateTime.to_date()

    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      _ -> "Older"
    end
  end

  defp time_label(ms) do
    t = to_local(ms)

    if NaiveDateTime.to_date(t) == NaiveDateTime.to_date(Cron.local_now()),
      do: Calendar.strftime(t, "%H:%M"),
      else: Calendar.strftime(t, "%b %-d")
  end

  ## Skills

  # {name, relative path} for skills that live in this project's folder.
  defp skill_files(project) do
    case Opencode.skills(project.directory) do
      {:ok, list} ->
        for s <- list, String.starts_with?(s["path"], project.directory <> "/") do
          {s["name"] || s["id"], Path.relative_to(s["path"], project.directory)}
        end
        |> Enum.sort()

      _ ->
        []
    end
  end

  @skill_template """
  ---
  name: NAME
  description: What /NAME does, in one line. OpenCode uses this to decide when to use it.
  ---

  Steps to follow when someone runs /NAME.
  """

  defp open_file(socket, path) do
    content =
      case Opencode.read_file(socket.assigns.project.directory, path) do
        {:ok, body} -> body
        _ -> ""
      end

    socket
    |> assign(file_path: path, file_form: to_form(%{"content" => content}, as: :file))
  end

  ## Schedules

  defp new_schedule_params(user) do
    %{
      "key" => "",
      "preset" => "weekdays",
      "at" => "08:00",
      "every" => "30",
      "cron" => "",
      "prompt" => "",
      "scope" => "team",
      "agent" => "",
      "model" => "",
      "owner" => user.username
    }
  end

  defp assign_schedule_form(socket, params) do
    cron = build_cron(params)

    next =
      case Cron.parse(cron) do
        {:ok, c} -> Cron.next(c, Cron.local_now())
        _ -> nil
      end

    socket
    |> assign(
      schedule_form: to_form(params, as: :schedule),
      schedule_cron: cron,
      schedule_next: next
    )
  end

  defp build_cron(%{"preset" => preset} = p) do
    {h, m} =
      case String.split(p["at"] || "", ":") do
        [h, m] -> {String.to_integer(h), String.to_integer(m)}
        _ -> {8, 0}
      end

    case preset do
      "every" -> "*/#{p["every"] || "30"} * * * *"
      "hourly" -> "#{m} * * * *"
      "daily" -> "#{m} #{h} * * *"
      "weekdays" -> "#{m} #{h} * * 1-5"
      "mondays" -> "#{m} #{h} * * 1"
      "fridays" -> "#{m} #{h} * * 5"
      _ -> p["cron"] || ""
    end
  rescue
    _ -> ""
  end

  defp params_from_schedule(%{key: key, raw: raw}) do
    cron = raw["cron"] || ""

    base = %{
      "key" => key,
      "prompt" => raw["prompt"] || "",
      "scope" => raw["scope"] || "team",
      "agent" => raw["agent"] || "",
      "model" => raw["model"] || "",
      "owner" => raw["owner"] || "",
      "every" => "30",
      "at" => "08:00",
      "cron" => cron
    }

    case String.split(cron) do
      ["*/" <> n, "*", "*", "*", "*"] ->
        Map.merge(base, %{"preset" => "every", "every" => n})

      [m, h, "*", "*", dow] when dow in ["*", "1-5", "1", "5"] ->
        preset = %{"*" => "daily", "1-5" => "weekdays", "1" => "mondays", "5" => "fridays"}[dow]
        at = String.pad_leading(h, 2, "0") <> ":" <> String.pad_leading(m, 2, "0")
        Map.merge(base, %{"preset" => preset, "at" => at})

      _ ->
        Map.put(base, "preset", "custom")
    end
  end

  defp list_agents(project) do
    case Opencode.agents(project.directory) do
      {:ok, agents} -> for a <- agents, a["mode"] != "subagent", !a["hidden"], do: a["id"]
      _ -> ["build", "plan"]
    end
  end

  defp list_models do
    case Opencode.models() do
      {:ok, models} ->
        for m <- models,
            m["enabled"] != false,
            m["status"] != "deprecated",
            do: {"#{m["providerID"]}/#{m["id"]}", m["name"]}

      _ ->
        []
    end
  end

  ## Events

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    socket = assign(socket, query: q)

    if routine?(socket) and socket.assigns.live_action == :sessions,
      do: {:noreply, stream_runs(socket)},
      else: {:noreply, stream_groups(socket)}
  end

  # Run: the main button runs with defaults, ▾ asks for inputs first.
  def handle_event("run", params, socket) do
    values = normalize_inputs(params["inputs"] || %{}, socket.assigns.routine)

    case Routines.run(socket.assigns.project, socket.assigns.current_scope.user, values) do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: ~p"/s/#{run.session_id}")}

      {:error, e} ->
        {:noreply, put_flash(socket, :error, "Run failed to start: #{Shell.format_error(e)}")}
    end
  end

  def handle_event("run_menu", _params, socket) do
    menu =
      if socket.assigns.run_menu,
        do: nil,
        else: to_form(stringify(Routines.defaults(socket.assigns.routine)), as: :inputs)

    {:noreply, assign(socket, run_menu: menu)}
  end

  def handle_event("close_run_menu", _params, socket),
    do: {:noreply, assign(socket, run_menu: nil)}

  def handle_event("toggle_worktree", _params, socket) do
    {:noreply, assign(socket, worktree: !socket.assigns.worktree)}
  end

  def handle_event("new_session", _params, socket) do
    {:noreply,
     Shell.new_session(socket, socket.assigns.project, worktree: socket.assigns.worktree)}
  end

  def handle_event("new_skill", _params, socket),
    do: {:noreply, assign(socket, new_skill: to_form(%{"name" => ""}, as: :skill))}

  def handle_event("cancel_skill", _params, socket),
    do: {:noreply, assign(socket, new_skill: nil)}

  def handle_event("create_skill", %{"skill" => %{"name" => name}}, socket) do
    name = name |> String.trim() |> String.downcase()
    path = ".opencode/skill/#{name}/SKILL.md"

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) ->
        {:noreply,
         put_flash(socket, :error, "Skill names are lowercase letters, digits and dashes.")}

      Enum.any?(socket.assigns.skills, fn {n, _} -> n == name end) ->
        {:noreply, put_flash(socket, :error, "/#{name} already exists.")}

      true ->
        content = String.replace(@skill_template, "NAME", name)

        case Opencode.write_file(socket.assigns.project.directory, path, content) do
          {:ok, _} ->
            dir = socket.assigns.project.directory
            _ = Opencode.reload_location(dir)
            skills = Enum.sort(Enum.uniq(skill_files(socket.assigns.project) ++ [{name, path}]))

            {:noreply,
             socket
             |> assign(skills: skills, new_skill: nil)
             |> open_file(path)}

          {:error, e} ->
            {:noreply, put_flash(socket, :error, "Could not create: #{Shell.format_error(e)}")}
        end
    end
  end

  def handle_event("open_file", %{"path" => path}, socket),
    do: {:noreply, open_file(socket, path)}

  def handle_event("save_file", %{"file" => %{"content" => content}}, socket) do
    dir = socket.assigns.project.directory

    case Opencode.write_file(dir, socket.assigns.file_path, content) do
      {:ok, _} ->
        _ = Opencode.reload_location(dir)

        {:noreply,
         socket
         |> assign(file_form: to_form(%{"content" => content}, as: :file))
         |> put_flash(:info, "Saved #{socket.assigns.file_path}.")}

      {:error, e} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{Shell.format_error(e)}")}
    end
  end

  def handle_event("schedule_change", %{"schedule" => params}, socket) do
    {:noreply,
     assign_schedule_form(socket, Map.merge(socket.assigns.schedule_form.params, params))}
  end

  def handle_event("schedule_save", %{"schedule" => params}, socket) do
    params = Map.merge(socket.assigns.schedule_form.params, params)
    attrs = Map.put(params, "cron", build_cron(params))

    attrs =
      if attrs["owner"] in [nil, ""],
        do: Map.put(attrs, "owner", socket.assigns.current_scope.user.username),
        else: attrs

    case Schedules.save(socket.assigns.project, params["key"], attrs) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Saved to schedules.json.") |> load_tab(:schedules)}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, Shell.format_error(msg))}
    end
  end

  def handle_event("schedule_edit", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.schedules, &(&1.key == key)) do
      nil ->
        {:noreply, socket}

      s ->
        {:noreply,
         socket |> assign(editing: key) |> assign_schedule_form(params_from_schedule(s))}
    end
  end

  def handle_event("schedule_new", _params, socket) do
    {:noreply,
     socket
     |> assign(editing: nil)
     |> assign_schedule_form(new_schedule_params(socket.assigns.current_scope.user))}
  end

  def handle_event("schedule_delete", %{"key" => key}, socket) do
    case Schedules.delete(socket.assigns.project, key) do
      :ok -> {:noreply, socket |> put_flash(:info, "Deleted #{key}.") |> load_tab(:schedules)}
      {:error, e} -> {:noreply, put_flash(socket, :error, Shell.format_error(e))}
    end
  end

  def handle_event("schedule_run", %{"key" => key}, socket) do
    with %{raw: raw} <- Enum.find(socket.assigns.schedules, &(&1.key == key)),
         {:ok, run} <- Schedules.run(socket.assigns.project, key, raw) do
      {:noreply, push_navigate(socket, to: ~p"/s/#{run.session_id}")}
    else
      {:error, e} -> {:noreply, put_flash(socket, :error, "Run failed: #{Shell.format_error(e)}")}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("settings_save", %{"settings" => params}, socket) do
    project = socket.assigns.project
    user = socket.assigns.current_scope.user

    if user.admin or project.owner_id == user.id do
      case Projects.update_settings(project, params) do
        {:ok, project} ->
          {:noreply,
           socket
           |> assign(project: project)
           |> Shell.set_current(project)
           |> put_flash(:info, "Saved.")
           |> load_tab(:settings)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only the owner or an admin can change this.")}
    end
  end

  def handle_event("grant", %{"connector" => name, "granted" => granted}, socket) do
    if socket.assigns.current_scope.user.admin do
      Connectors.set_granted(name, socket.assigns.project.name, granted == "true")
      Connectors.sync_all()
      {:noreply, load_tab(socket, :settings)}
    else
      {:noreply, put_flash(socket, :error, "Admins grant connectors.")}
    end
  end

  def handle_event("github_save", %{"github" => %{"token" => token}}, socket) do
    project = socket.assigns.project
    user = socket.assigns.current_scope.user

    if user.admin or project.owner_id == user.id do
      {:noreply,
       socket
       |> assign(github_saving: true, github_error: nil)
       |> start_async(:github_save, fn -> GitTokens.save(project, token, user) end)}
    else
      {:noreply, put_flash(socket, :error, "Only the owner or an admin can change this.")}
    end
  end

  def handle_event("github_remove", _params, socket) do
    project = socket.assigns.project
    user = socket.assigns.current_scope.user

    if user.admin or project.owner_id == user.id do
      case GitTokens.delete(project) do
        :ok ->
          {:noreply, socket |> put_flash(:info, "Token removed.") |> load_tab(:settings)}

        error ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Removed from the vault, but not from the server: #{Shell.format_error(error)}"
           )
           |> load_tab(:settings)}
      end
    else
      {:noreply, put_flash(socket, :error, "Only the owner or an admin can change this.")}
    end
  end

  def handle_event("remove_project", _params, socket) do
    if socket.assigns.current_scope.user.admin and socket.assigns.project.kind != "system" do
      project = socket.assigns.project
      {:ok, _} = Projects.delete_project(project)

      # Keyed by name, so a later project with the same name must not inherit it.
      if project.kind == "code",
        do:
          Task.Supervisor.start_child(Beamcode.TaskSupervisor, fn -> GitTokens.delete(project) end)

      {:noreply,
       socket
       |> put_flash(:info, "Removed from Peon. The folder is still on the server.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, put_flash(socket, :error, "Admins only.")}
    end
  end

  @impl true
  def handle_async(:routine, {:ok, config}, socket),
    do: {:noreply, assign(socket, routine: config)}

  def handle_async(:routine, _, socket), do: {:noreply, socket}

  def handle_async(:github_save, {:ok, {:ok, project}}, socket) do
    {:noreply,
     socket
     |> assign(project: project)
     |> put_flash(:info, "Token saved. Sessions in #{project.github_repo} can push and open PRs.")
     |> load_tab(:settings)}
  end

  def handle_async(:github_save, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, github_saving: false, github_error: Shell.format_error(reason))}

  def handle_async(:github_save, {:exit, reason}, socket),
    do: {:noreply, assign(socket, github_saving: false, github_error: inspect(reason))}

  defp stringify(values),
    do:
      Map.new(values, fn {k, v} ->
        {k, if(is_list(v), do: Enum.map(v, &to_string/1), else: to_string(v))}
      end)

  # Checkbox groups arrive as lists; drop the empty marker value.
  defp normalize_inputs(params, nil), do: params

  defp normalize_inputs(params, config) do
    Map.new(config.inputs, fn input ->
      value = Map.get(params, input.name, input.default)
      value = if input.multi, do: List.wrap(value) |> Enum.reject(&(&1 == "")), else: value
      {input.name, value}
    end)
  end

  # Called by BeamcodeWeb.Shell for shortcuts.
  def handle_keybind(_action, socket), do: socket

  @impl true
  def handle_info({:oc_activity, _type, _data}, socket) do
    if socket.assigns.live_action in [:sessions, :chats] and socket.assigns.refresh_ref == nil do
      {:noreply, assign(socket, refresh_ref: Process.send_after(self(), :refresh_sessions, 400))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_sessions, socket) do
    {:noreply, socket |> assign(refresh_ref: nil) |> load_tab(socket.assigns.live_action)}
  end

  def handle_info({:runs_changed, _}, socket) do
    case socket.assigns.live_action do
      :schedules ->
        {:noreply, load_tab(socket, :schedules)}

      :sessions ->
        if routine?(socket), do: {:noreply, load_runs(socket)}, else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={@project.id}>
      <Layouts.page_header title={@project.name} subtitle={subtitle(@project)}>
        <:actions>
          <label
            :if={@project.kind == "code" and @live_action == :sessions}
            class="flex items-center gap-2 text-[12.5px] text-muted cursor-pointer select-none"
            title="Start the session in a fresh git worktree"
          >
            <input
              type="checkbox"
              class="checkbox"
              id="worktree-toggle"
              checked={@worktree}
              phx-click="toggle_worktree"
            /> new worktree
          </label>
          <%= if @project.kind == "routine" do %>
            <button
              class="btn"
              id="new-session"
              phx-click="new_session"
              phx-disable-with="Starting…"
            >
              Chat
            </button>
            <div class="relative flex" id="run-split">
              <button
                class="btn btn-primary rounded-r-none pr-3"
                id="run-button"
                phx-click="run"
                phx-disable-with="Starting…"
                title="Run with the defaults from routine.json"
              >
                Run
              </button>
              <button
                class="btn btn-primary rounded-l-none px-2 border-l border-canvas/20"
                id="run-menu-button"
                phx-click="run_menu"
                title="Run with inputs"
              >
                <.icon name="hero-chevron-down-micro" class="size-4" />
              </button>
              <.run_menu :if={@run_menu} form={@run_menu} routine={@routine} project={@project} />
            </div>
          <% else %>
            <button
              class="btn btn-primary"
              id="new-session"
              phx-click="new_session"
              phx-disable-with="Starting…"
            >
              {if @project.kind == "chat", do: "New chat", else: "New session"}
            </button>
          <% end %>
        </:actions>
      </Layouts.page_header>

      <nav id="project-tabs" class="flex-none flex gap-1 px-6 border-b border-line">
        <.tab_link to={~p"/p/#{@project.id}"} active={@live_action == :sessions} id="tab-sessions">
          {if @project.kind == "routine", do: "Runs", else: "Sessions"}
        </.tab_link>
        <.tab_link
          :if={@project.kind == "routine"}
          to={~p"/p/#{@project.id}/chats"}
          active={@live_action == :chats}
          id="tab-chats"
        >Chats</.tab_link>
        <.tab_link
          to={~p"/p/#{@project.id}/skills"}
          active={@live_action == :skills}
          id="tab-skills"
        >Skills</.tab_link>
        <.tab_link
          to={~p"/p/#{@project.id}/schedules"}
          active={@live_action == :schedules}
          id="tab-schedules"
        >Schedules</.tab_link>
        <.tab_link
          to={~p"/p/#{@project.id}/settings"}
          active={@live_action == :settings}
          id="tab-settings"
        >Settings</.tab_link>
      </nav>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <%= case @live_action do %>
          <% :sessions -> %>
            {if @project.kind == "routine", do: runs_tab(assigns), else: sessions_tab(assigns)}
          <% :chats -> %>
            {sessions_tab(assigns)}
          <% :skills -> %>
            {skills_tab(assigns)}
          <% :schedules -> %>
            {schedules_tab(assigns)}
          <% :settings -> %>
            {settings_tab(assigns)}
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :routine, :map, default: nil
  attr :project, :map, required: true

  defp run_menu(assigns) do
    ~H"""
    <div
      id="run-menu"
      phx-click-away="close_run_menu"
      phx-window-keydown="close_run_menu"
      phx-key="Escape"
      class="absolute right-0 top-full mt-2 z-30 w-[380px] rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line2),0_24px_60px_-24px_rgba(0,0,0,.8)] p-4"
      style="animation: pop-in .14s ease-out"
    >
      <div class="text-[14px] font-semibold">Run {@project.name}</div>
      <div :if={@routine} class="font-mono text-[12px] text-muted mt-0.5 mb-3 truncate">
        {@routine.run}
      </div>
      <p :if={@routine && @routine.error} class="text-[12.5px] text-del mb-2">{@routine.error}</p>
      <.form for={@form} id="run-form" phx-submit="run" class="flex flex-col gap-3.5">
        <div :for={input <- (@routine && @routine.inputs) || []} class="flex flex-col gap-1.5">
          <span class="text-[12.5px] text-muted capitalize">{input.name}</span>
          <%= cond do %>
            <% input.options == [] -> %>
              <input
                name={"inputs[#{input.name}]"}
                value={@form.params[input.name]}
                class="input h-9"
                autocomplete="off"
              />
            <% input.multi -> %>
              <div class="flex flex-wrap gap-1.5">
                <input type="hidden" name={"inputs[#{input.name}][]"} value="" />
                <label
                  :for={opt <- input.options}
                  class="h-8 flex items-center px-3 rounded-lg bg-raised text-[13px] cursor-pointer has-checked:bg-fg has-checked:text-canvas transition"
                >
                  <input
                    type="checkbox"
                    class="sr-only"
                    name={"inputs[#{input.name}][]"}
                    value={opt}
                    checked={opt in List.wrap(@form.params[input.name])}
                  />
                  {opt}
                </label>
              </div>
            <% true -> %>
              <div class="flex flex-wrap gap-1.5">
                <label
                  :for={opt <- input.options}
                  class="h-8 flex items-center px-3 rounded-lg bg-raised text-[13px] cursor-pointer has-checked:bg-fg has-checked:text-canvas transition"
                >
                  <input
                    type="radio"
                    class="sr-only"
                    name={"inputs[#{input.name}]"}
                    value={opt}
                    checked={@form.params[input.name] == opt}
                  />
                  {opt}
                </label>
              </div>
          <% end %>
        </div>
        <p :if={@routine && @routine.inputs == []} class="text-[12.5px] text-faint">
          No inputs. Add them in routine.json to ask for choices on each run.
        </p>
        <div class="flex items-center gap-2 pt-1">
          <span class="text-[12px] text-faint">Inputs come from routine.json</span>
          <button type="submit" class="btn btn-primary ml-auto" id="run-with-inputs">
            Run <span class="font-mono text-[11px] opacity-60">↵</span>
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp runs_tab(assigns) do
    ~H"""
    <div class="px-16 py-8 max-w-[1040px] flex flex-col">
      <form id="run-search-form" phx-change="search" phx-submit="search" class="mb-1">
        <div class="h-11 flex items-center gap-2.5 px-4 rounded-[10px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] focus-within:shadow-[inset_0_0_0_1px_#4a4952]">
          <input
            id="session-search"
            data-kb-search
            name="q"
            value={@query}
            autocomplete="off"
            phx-debounce="100"
            placeholder="Search runs and results"
            class="flex-1 bg-transparent outline-none text-[14px] placeholder:text-faint"
          />
          <span class="font-mono text-[11px] px-1.5 py-0.5 rounded-[5px] bg-raised text-fg">/</span>
        </div>
      </form>

      <div :if={@loaded && @empty?} id="runs-empty" class="mt-10 text-center text-[13.5px] text-faint">
        {if @query == "", do: "No runs yet. Press Run to start one.", else: "No runs match."}
      </div>

      <div id="run-groups" phx-update="stream" class="flex flex-col">
        <div :for={{dom_id, group} <- @streams.run_groups} id={dom_id} class="flex flex-col">
          <span class="pt-[18px] pb-1.5 px-3 text-[13px] text-muted">{group.label}</span>
          <.link
            :for={run <- group.runs}
            navigate={if run.session_id, do: ~p"/s/#{run.session_id}", else: ~p"/p/#{@project.id}"}
            id={"run-row-#{run.id}"}
            data-kb-row
            class="min-h-[52px] py-2 flex items-center gap-3 px-3 rounded-[9px] hover:bg-hov transition"
          >
            <div class="flex-1 min-w-0 flex flex-col">
              <span class="text-[14.5px] truncate">{run_title(run)}</span>
              <span class={[
                "text-[12.5px] truncate",
                if(run.status == "failed", do: "text-del", else: "text-muted")
              ]}>
                {cond do
                  run.status == "running" -> "running…"
                  run.status == "failed" -> "failed · " <> (run.error || "")
                  true -> run.summary || "done"
                end}
              </span>
            </div>
            <span class="text-[12.5px] text-faint whitespace-nowrap">
              {run_who(run, @current_scope.user)}{if l = inputs_label(run.inputs), do: " · " <> l}
            </span>
            <Layouts.status_badge :if={run.status == "running"} status={:running} />
            <span class="w-[60px] flex-none text-right text-[12.5px] text-muted">{run_duration(run)}</span>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp subtitle(%{kind: "routine"} = p) do
    scope = if p.scope == "private", do: " · only you", else: ""
    "Routine · #{Schedules.summary(p.id) || "no schedule"}#{scope}"
  end

  defp subtitle(p) do
    kind =
      %{
        "code" => "Code",
        "routine" => "Routine",
        "chat" => "Chat",
        "system" => "System · admins only"
      }[p.kind]

    scope = if p.scope == "private", do: " · only you", else: ""
    "#{kind} · #{p.directory}#{scope}"
  end

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  attr :id, :string, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={@to}
      id={@id}
      aria-current={@active && "page"}
      class={[
        "h-10 flex items-center px-3 text-[13.5px] border-b-2 -mb-px transition",
        if(@active, do: "border-fg text-fg", else: "border-transparent text-muted hover:text-fg")
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp sessions_tab(assigns) do
    ~H"""
    <div class="px-16 py-8 max-w-[1040px] flex flex-col">
      <form id="session-search-form" phx-change="search" phx-submit="search" class="mb-1">
        <div class="h-11 flex items-center gap-2.5 px-4 rounded-[10px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] focus-within:shadow-[inset_0_0_0_1px_#4a4952]">
          <input
            id="session-search"
            data-kb-search
            name="q"
            value={@query}
            autocomplete="off"
            phx-debounce="100"
            placeholder={"Search sessions in #{@project.name}"}
            class="flex-1 bg-transparent outline-none text-[14px] placeholder:text-faint"
          />
          <span class="font-mono text-[11px] px-1.5 py-0.5 rounded-[5px] bg-raised text-fg">/</span>
        </div>
      </form>

      <p :if={@loaded && @load_error} class="mt-6 text-[13px] text-del">{@load_error}</p>
      <div
        :if={@loaded && !@load_error && @empty?}
        id="sessions-empty"
        class="mt-10 text-center text-[13.5px] text-faint"
      >
        {if @query == "",
          do: "No sessions yet. Start one with New session.",
          else: "No sessions match."}
      </div>

      <div id="session-groups" phx-update="stream" class="flex flex-col">
        <div :for={{dom_id, group} <- @streams.groups} id={dom_id} class="flex flex-col">
          <span class="pt-[18px] pb-1.5 px-3 text-[13px] text-muted">{group.label}</span>
          <.link
            :for={s <- group.sessions}
            navigate={~p"/s/#{s["id"]}"}
            id={"session-row-#{s["id"]}"}
            data-kb-row
            class="h-11 flex items-center gap-3 px-3 rounded-[9px] hover:bg-hov transition"
          >
            <Layouts.avatar name={@project.name} status={Events.status(s["id"])} />
            <span class="flex-1 min-w-0 text-[14.5px] truncate">{s["title"] || "New session"}</span>
            <span :if={s["record"] && s["record"].schedule_key} class="text-[11.5px] text-faint">scheduled</span>
            <span
              :if={s["record"] && s["record"].scope == "private"}
              class="text-faint"
              title="Only you"
            >
              <.icon name="hero-lock-closed-micro" class="size-3" />
            </span>
            <span
              :if={worktree?(s, @project)}
              class="text-[11.5px] text-faint"
              title={get_in(s, ["location", "directory"])}
            >
              worktree
            </span>
            <Layouts.status_badge status={Events.status(s["id"])} />
            <span class="w-[90px] flex-none text-right text-[12.5px] text-muted">
              {time_label(get_in(s, ["time", "updated"]))}
            </span>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, default: nil

  defp file_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"file-" <> String.replace(@path, ~r/[^a-zA-Z0-9]/, "-")}
      phx-click="open_file"
      phx-value-path={@path}
      title={@path}
      class={[
        "h-9 text-left px-2.5 rounded-lg font-mono text-[12.5px] truncate transition",
        if(@path == @current, do: "bg-hov text-fg", else: "text-muted hover:bg-panel hover:text-fg")
      ]}
    >
      {@label}
    </button>
    """
  end

  defp worktree?(s, project),
    do: get_in(s, ["location", "directory"]) not in [nil, project.directory]

  defp skills_tab(assigns) do
    ~H"""
    <div class="px-10 py-8 flex gap-8 max-w-[1200px]">
      <div class="w-[260px] flex-none flex flex-col gap-0.5">
        <span class="px-2.5 pb-2 text-[13px] text-muted">Instructions</span>
        <.file_button path="AGENTS.md" label="AGENTS.md" current={@file_path} />

        <div class="flex items-center px-2.5 pt-5 pb-2 text-[13px] text-muted">
          <span class="flex-1">Skills</span>
          <button
            :if={!@new_skill}
            type="button"
            id="new-skill"
            phx-click="new_skill"
            class="text-[12.5px] hover:text-fg transition"
          >
            + New skill
          </button>
        </div>
        <.form
          :if={@new_skill}
          for={@new_skill}
          id="new-skill-form"
          phx-submit="create_skill"
          class="flex items-center gap-1.5 px-1 pb-1.5"
        >
          <span class="font-mono text-[12.5px] text-muted pl-1.5">/</span>
          <input
            id="new-skill-name"
            name="skill[name]"
            placeholder="digest"
            autocomplete="off"
            phx-mounted={JS.focus()}
            phx-keydown="cancel_skill"
            phx-key="Escape"
            class="input h-8 font-mono text-[12.5px]"
          />
          <button type="submit" class="btn btn-primary btn-sm" id="create-skill">Add</button>
        </.form>
        <.file_button
          :for={{name, path} <- @skills}
          path={path}
          label={"/" <> name}
          current={@file_path}
        />
        <span :if={@skills == [] and !@new_skill} class="px-2.5 text-[12.5px] text-faint">
          No skills yet.
        </span>

        <p class="px-2.5 pt-5 text-[12.5px] text-faint leading-relaxed">
          AGENTS.md is what every session in this project reads first. A skill is a
          reusable step: run it with <span class="font-mono">/name</span> in a session or a schedule.
          Edit here, or ask a session to change them.
        </p>
      </div>
      <.form
        for={@file_form}
        id="file-form"
        phx-submit="save_file"
        class="flex-1 min-w-0 flex flex-col gap-3"
      >
        <div class="flex items-center gap-2">
          <span class="font-mono text-[13px]">{@file_path}</span>
          <button type="submit" class="btn btn-primary btn-sm ml-auto" id="save-file">Save</button>
        </div>
        <textarea
          id="file-content"
          name="file[content]"
          spellcheck="false"
          class="textarea font-mono text-[13px] leading-relaxed min-h-[60vh]"
        >{@file_form.params["content"]}</textarea>
      </.form>
    </div>
    """
  end

  defp schedules_tab(assigns) do
    ~H"""
    <div class="px-10 py-8 flex gap-8 max-w-[1200px]">
      <div class="w-[480px] flex-none">
        <.form
          for={@schedule_form}
          id="schedule-form"
          phx-change="schedule_change"
          phx-submit="schedule_save"
          class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5"
        >
          <div class="flex items-center mb-4">
            <span class="text-[15px] font-semibold">{if @editing,
              do: "Edit #{@editing}",
              else: "Add a schedule"}</span>
            <button
              :if={@editing}
              type="button"
              phx-click="schedule_new"
              class="ml-auto text-[12.5px] text-muted hover:text-fg"
              id="schedule-new"
            >
              + new
            </button>
          </div>
          <.input
            field={@schedule_form[:key]}
            label="Name"
            placeholder="morning-digest"
            autocomplete="off"
            readonly={@editing != nil}
          />
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@schedule_form[:preset]}
              type="select"
              label="When"
              options={[
                {"Weekdays", "weekdays"},
                {"Every day", "daily"},
                {"Mondays", "mondays"},
                {"Fridays", "fridays"},
                {"Every N minutes", "every"},
                {"Every hour", "hourly"},
                {"Custom cron", "custom"}
              ]}
            />
            <%= case @schedule_form.params["preset"] do %>
              <% "every" -> %>
                <.input
                  field={@schedule_form[:every]}
                  type="select"
                  label="Every"
                  options={[{"5 min", "5"}, {"10 min", "10"}, {"15 min", "15"}, {"30 min", "30"}]}
                />
              <% "custom" -> %>
                <.input
                  field={@schedule_form[:cron]}
                  label="Cron"
                  placeholder="0 8 * * 1-5"
                  class="input font-mono"
                />
              <% "hourly" -> %>
                <div></div>
              <% _ -> %>
                <.input field={@schedule_form[:at]} type="time" label="At" />
            <% end %>
          </div>
          <div class="-mt-1 mb-4 font-mono text-[12px] text-muted">
            {@schedule_cron} · {if @schedule_next,
              do: "next run " <> Calendar.strftime(@schedule_next, "%a %-d %b %H:%M"),
              else: "invalid"}
          </div>
          <.input
            field={@schedule_form[:prompt]}
            type="textarea"
            rows="2"
            label={
              if @project.kind == "routine",
                do: "Prompt (blank runs the routine with its defaults)",
                else: "Send this to a new session"
            }
            placeholder={
              if @project.kind == "routine", do: "blank = Run", else: "/digest since the last run"
            }
          />
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@schedule_form[:agent]}
              type="select"
              label="Agent"
              prompt="default"
              options={@agents}
            />
            <.input
              field={@schedule_form[:model]}
              type="select"
              label="Model"
              prompt="default"
              options={Enum.map(@models, fn {v, l} -> {l, v} end)}
            />
          </div>
          <div class="fieldset">
            <span class="label">Who it's for</span>
            <div class="flex gap-2">
              <label
                :for={{v, l} <- [{"me", "Only me"}, {"team", "Team"}]}
                class="h-8 flex items-center px-3 rounded-lg bg-raised text-[13px] cursor-pointer has-checked:bg-fg has-checked:text-canvas transition"
              >
                <input
                  type="radio"
                  name="schedule[scope]"
                  value={v}
                  checked={@schedule_form.params["scope"] == v}
                  class="sr-only"
                />
                {l}
              </label>
            </div>
            <span class="text-[12.5px] text-faint mt-1">
              {if @schedule_form.params["scope"] == "me",
                do: "Runs and Inbox items are visible only to you.",
                else:
                  "Everyone with access to #{@project.name} sees runs and can approve. Owner: #{@schedule_form.params["owner"]}"}
            </span>
          </div>
          <div class="flex items-center gap-2 mt-2">
            <span class="font-mono text-[11.5px] text-faint">// saved in {@project.name}/schedules.json</span>
            <button type="submit" class="btn btn-primary ml-auto" id="schedule-save">Save</button>
          </div>
        </.form>
      </div>

      <div class="flex-1 min-w-0 flex flex-col gap-4">
        <p :if={@schedules_error} class="text-[13px] text-del">{@schedules_error}</p>
        <div
          :if={@schedules == [] and !@schedules_error}
          id="schedules-empty"
          class="text-[13.5px] text-faint pt-2"
        >
          No schedules yet. Each run is a normal session you can open.
        </div>
        <div
          :for={s <- @schedules}
          id={"schedule-#{s.key}"}
          class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-4 flex flex-col gap-3"
        >
          <div class="flex items-center gap-2">
            <span class="text-[14.5px] font-semibold">{s.key}</span>
            <span class="text-[12.5px] text-muted">{s.when}</span>
            <span class="text-[11.5px] px-1.5 h-5 flex items-center rounded-md bg-raised text-muted">
              {if s.scope == "me", do: "Only me", else: "Team"}
            </span>
            <div class="ml-auto flex gap-1.5">
              <button
                class="btn btn-sm"
                phx-click="schedule_run"
                phx-value-key={s.key}
                id={"run-#{s.key}"}
                phx-disable-with="Starting…"
              >Run now</button>
              <button
                class="btn btn-sm"
                phx-click="schedule_edit"
                phx-value-key={s.key}
                id={"edit-#{s.key}"}
              >Edit</button>
              <button
                class="btn btn-sm btn-danger"
                phx-click="schedule_delete"
                phx-value-key={s.key}
                id={"delete-#{s.key}"}
                data-confirm={"Delete #{s.key}?"}
              >Delete</button>
            </div>
          </div>
          <div class="font-mono text-[12.5px] text-soft bg-code rounded-lg px-3 py-2 truncate">
            {s.prompt}
          </div>
          <div class="text-[12px] text-muted">
            Next run {if s.next, do: Calendar.strftime(s.next, "%a %-d %b %H:%M"), else: "—"} · owner {s.owner ||
              "—"}
          </div>
          <div class="flex flex-col">
            <span class="text-[12.5px] text-muted pb-1">Runs · each one is a normal session</span>
            <.run_row :for={r <- Schedules.runs(@project.id, s.key, 5)} run={r} />
            <span :if={s.last == nil} class="text-[12.5px] text-faint">No runs yet.</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :run, :map, required: true

  def run_row(assigns) do
    ~H"""
    <.link
      navigate={if @run.session_id, do: ~p"/s/#{@run.session_id}", else: "#"}
      id={"run-row-#{@run.id}"}
      class="h-9 flex items-center gap-3 px-2 -mx-2 rounded-lg hover:bg-hov transition text-[13px]"
    >
      <span class="w-[140px] text-muted">{Calendar.strftime(
        local(@run.inserted_at),
        "%a %-d %b %H:%M"
      )}</span>
      <span class="flex-1 truncate text-faint">{@run.error}</span>
      <span class={[
        "text-[11.5px] px-1.5 h-5 flex items-center rounded-md",
        @run.status == "done" && "bg-addbg text-add",
        @run.status == "failed" && "bg-delbg text-del",
        @run.status == "running" && "bg-runbg text-run"
      ]}>
        {@run.status}
      </span>
    </.link>
    """
  end

  defp local(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  defp settings_tab(assigns) do
    ~H"""
    <div class="px-10 py-8 max-w-[640px] flex flex-col gap-8">
      <.form for={@settings_form} id="settings-form" phx-submit="settings_save" class="flex flex-col">
        <div class="fieldset">
          <span class="label">Who can see it</span>
          <div class="flex gap-2">
            <label
              :for={{v, l} <- [{"team", "Team"}, {"private", "Only me"}]}
              class="h-8 flex items-center px-3 rounded-lg bg-raised text-[13px] cursor-pointer has-checked:bg-fg has-checked:text-canvas transition"
            >
              <input
                type="radio"
                name="settings[scope]"
                value={v}
                checked={@settings_form.params["scope"] == v}
                class="sr-only"
              />
              {l}
            </label>
          </div>
          <span class="text-[12.5px] text-faint mt-1">
            Only me hides the project, its sessions and its Inbox items from everyone else.
          </span>
        </div>
        <.input
          :if={@project.kind == "code"}
          field={@settings_form[:always_worktree]}
          type="checkbox"
          label="Always start sessions in a new git worktree"
        />
        <div>
          <button type="submit" class="btn btn-primary" id="settings-save">Save</button>
        </div>
      </.form>

      <.form
        :if={@project.kind == "code"}
        for={@github_form}
        id="github-form"
        phx-submit="github_save"
        class="flex flex-col gap-2"
      >
        <div class="flex items-baseline gap-2">
          <span class="text-[13px] text-muted">GitHub token</span>
          <span :if={@project.github_repo} class="font-mono text-[12.5px] text-soft">
            {@project.github_repo}
          </span>
        </div>
        <div
          :if={@github_hint}
          id="github-token-set"
          class="h-11 flex items-center gap-3 px-3.5 rounded-[10px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)]"
        >
          <.icon name="hero-key" class="size-4 text-muted" />
          <span class="font-mono text-[12.5px] text-soft">{@github_hint}</span>
          <span class="text-[12.5px] text-muted">sessions can push and open PRs</span>
          <button
            type="button"
            class="btn btn-sm ml-auto"
            id="github-remove"
            phx-click="github_remove"
            data-confirm="Remove the token? Sessions can no longer push to this repo."
          >
            Remove
          </button>
        </div>
        <div class="flex gap-2 items-start">
          <div class="flex-1 [&_.fieldset]:mb-0">
            <.input
              field={@github_form[:token]}
              type="password"
              placeholder={if @github_hint, do: "Replace with a new token", else: "github_pat_…"}
              autocomplete="off"
            />
          </div>
          <button type="submit" class="btn" id="github-save" disabled={@github_saving}>
            <.icon :if={@github_saving} name="hero-arrow-path" class="size-4 animate-spin" />
            {if @github_hint, do: "Replace", else: "Save"}
          </button>
        </div>
        <p :if={@github_error} id="github-error" class="text-[13px] text-del">{@github_error}</p>
        <span class="text-[12.5px] text-faint leading-snug text-pretty">
          A
          <a
            href="https://github.com/settings/personal-access-tokens/new"
            target="_blank"
            rel="noopener"
            class="text-soft underline underline-offset-2 hover:text-fg"
          >fine-grained token</a>
          for just this repo, with Contents and Pull requests set to read and write.
          <%= if !@project.github_repo do %>
            The repo is read from origin, which is switched to HTTPS.
          <% end %>
          Sessions can read it.
        </span>
      </.form>

      <div :if={@connectors != []} class="flex flex-col gap-2" id="project-connectors">
        <span class="text-[13px] text-muted">Connectors</span>
        <div
          :for={c <- @connectors}
          class="h-11 flex items-center gap-3 px-3.5 rounded-[10px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)]"
        >
          <span class="text-[14px] font-medium">{c.name}</span>
          <span class="text-[12.5px] text-muted">{length(c.tools)} tools</span>
          <span :if={!Connectors.ready?(c, @secrets)} class="text-[12px] text-wait">secret not set</span>
          <button
            :if={@current_scope.user.admin}
            type="button"
            class="btn btn-sm ml-auto"
            id={"grant-#{c.name}"}
            phx-click="grant"
            phx-value-connector={c.name}
            phx-value-granted={to_string(@project.name not in c.projects)}
          >
            {if @project.name in c.projects, do: "Revoke", else: "Grant"}
          </button>
          <span :if={!@current_scope.user.admin} class="ml-auto text-[12.5px] text-muted">
            {if @project.name in c.projects, do: "granted", else: "—"}
          </span>
        </div>
      </div>

      <div
        :if={@current_scope.user.admin and @project.kind != "system"}
        class="pt-4 border-t border-line"
      >
        <button
          class="btn btn-danger"
          id="remove-project"
          phx-click="remove_project"
          data-confirm="Remove from Peon? The folder stays on the server."
        >
          Remove from Peon
        </button>
      </div>
    </div>
    """
  end
end
