defmodule BeamcodeWeb.Shell do
  @moduledoc """
  `on_mount` hook for every signed-in LiveView. Keeps the app chrome up to date:
  sidebar projects, session tabs (running/waiting), Inbox count, the command
  palette, the global composer and global keyboard shortcuts.

  Views set the current project/session with `set_current/3`. Views may define
  `handle_keybind/2` to receive view-specific shortcuts.
  """
  import Phoenix.Component
  import Phoenix.LiveView
  use BeamcodeWeb, :verified_routes
  alias Beamcode.{Composer, Inbox, Keybinds, Projects, Schedules, Sessions}
  alias Beamcode.Opencode.Events

  @global_actions ~w(session_new)

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Projects.subscribe()
      Events.subscribe_activity()
      Schedules.subscribe()
    end

    socket =
      socket
      |> assign(current_project: nil, current_session_id: nil, palette: nil)
      |> assign(:composer, %{text: "", parsed: nil, busy: false})
      |> assign_keybinds(socket.assigns.current_scope.user)
      |> refresh()
      |> attach_hook(:shell_info, :handle_info, &handle_info/2)
      |> attach_hook(:shell_event, :handle_event, &handle_event/3)
      |> attach_hook(:shell_async, :handle_async, &handle_async/3)

    {:cont, socket}
  end

  @doc "Assigns the user's in-session bindings and keymap preferences."
  def assign_keybinds(socket, user) do
    assign(socket, keybinds: Keybinds.merged(user), kb_prefs: Keybinds.prefs(user))
  end

  def set_current(socket, project, session_id \\ nil) do
    socket
    |> assign(current_project: project, current_session_id: session_id)
    |> refresh_tabs()
  end

  def refresh(socket) do
    user = socket.assigns.current_scope.user
    projects = Projects.list_visible(user)

    socket
    |> assign(:shell_projects, projects)
    |> assign(:shell_inbox, Inbox.count(user, projects))
    |> refresh_tabs()
  end

  defp refresh_tabs(socket) do
    user = socket.assigns.current_scope.user
    projects = socket.assigns.shell_projects
    current = socket.assigns.current_session_id
    ids = Enum.uniq(Events.running_ids() ++ List.wrap(current))
    records = Projects.session_records(ids)

    tabs =
      for id <- ids,
          info = Events.session_info(id),
          info != nil,
          project = Projects.project_for_session(info, projects),
          project != nil,
          Projects.session_visible?(records[id], user) do
        %{
          id: id,
          title: info["title"] || "New session",
          project: project,
          status: Events.status(id)
        }
      end

    assign(socket, :shell_tabs, tabs)
  end

  @doc "Starts a session in `project` (worktree per project setting unless given) and navigates to it."
  def new_session(socket, project, opts \\ []) do
    user = socket.assigns.current_scope.user
    worktree = Keyword.get(opts, :worktree, project.always_worktree)

    case Sessions.start(project, user, worktree: worktree) do
      {:ok, session} ->
        push_navigate(socket, to: ~p"/s/#{session["id"]}")

      {:error, reason} ->
        put_flash(socket, :error, "Could not start a session: #{format_error(reason)}")
    end
  end

  def format_error({_status, msg}) when is_binary(msg), do: msg
  def format_error({:transport, msg}), do: "OpenCode server unreachable (#{msg})"
  def format_error(msg) when is_binary(msg), do: msg
  def format_error(other), do: inspect(other)

  defp handle_info(msg, socket) do
    case msg do
      {:oc_activity, _, _} -> pass(msg, refresh(socket))
      {:project_changed, _} -> pass(msg, refresh(socket))
      {:runs_changed, _} -> pass(msg, refresh(socket))
      {:schedules_changed, _} -> pass(msg, socket)
      _ -> {:cont, socket}
    end
  end

  # Let the view see shared messages only if it handles messages at all.
  defp pass(_msg, socket) do
    if function_exported?(socket.view, :handle_info, 2),
      do: {:cont, socket},
      else: {:halt, socket}
  end

  defp handle_event("palette_open", params, socket),
    do: {:halt, open_palette(socket, params["mode"] || "all")}

  defp handle_event("palette_close", _params, socket), do: {:halt, assign(socket, :palette, nil)}

  defp handle_event("palette_filter", %{"q" => q}, socket) do
    mode = socket.assigns.palette[:mode] || "all"

    {:halt,
     assign(socket, :palette, %{mode: mode, query: q, items: palette_items(socket, mode, q)})}
  end

  defp handle_event("palette_new_session", _params, socket) do
    socket = assign(socket, :palette, nil)

    case socket.assigns.current_project do
      nil -> {:halt, push_navigate(socket, to: ~p"/new")}
      project -> {:halt, new_session(socket, project)}
    end
  end

  ## Global composer

  defp handle_event("composer_change", %{"text" => text}, socket),
    do: {:halt, put_composer(socket, text)}

  defp handle_event("composer_submit", %{"text" => text}, socket),
    do: {:halt, socket |> put_composer(text) |> start_composer()}

  # A project picked from the preview when the line named none.
  defp handle_event("composer_pick", %{"id" => id}, socket) do
    %{composer: composer, shell_projects: projects} = socket.assigns

    case {composer.parsed, Enum.find(projects, &(to_string(&1.id) == id))} do
      {%{} = parsed, %{} = project} ->
        parsed = %{parsed | project: project, action: :session}
        {:halt, socket |> assign(:composer, %{composer | parsed: parsed}) |> start_composer()}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_event("keybind", %{"action" => action}, socket) when action in @global_actions do
    project = socket.assigns.current_project

    socket =
      case {action, project} do
        {"session_new", nil} -> put_flash(socket, :info, "Open a project to start a session.")
        {"session_new", project} -> new_session(socket, project)
      end

    {:halt, socket}
  end

  defp handle_event("keybind", %{"action" => action}, socket) do
    if function_exported?(socket.view, :handle_keybind, 2) do
      {:halt, socket.view.handle_keybind(action, socket)}
    else
      {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp put_composer(socket, text) do
    parsed = Composer.parse(text, socket.assigns.shell_projects)
    assign(socket, :composer, %{socket.assigns.composer | text: text, parsed: parsed})
  end

  defp start_composer(%{assigns: %{composer: %{busy: true}}} = socket), do: socket
  defp start_composer(%{assigns: %{composer: %{parsed: nil}}} = socket), do: socket

  defp start_composer(%{assigns: %{composer: %{parsed: %{project: nil}}}} = socket),
    do: put_flash(socket, :error, "Say which project, e.g. “in chatos-web”.")

  defp start_composer(socket) do
    %{composer: composer, current_scope: %{user: user}} = socket.assigns
    parsed = composer.parsed

    socket
    |> assign(:composer, %{composer | busy: true})
    |> start_async(:composer_start, fn -> {parsed, Composer.start(parsed, user)} end)
  end

  defp handle_async(:composer_start, result, socket) do
    socket = assign(socket, :composer, %{socket.assigns.composer | busy: false})

    socket =
      case result do
        {:ok, {parsed, {:ok, session_id}}} ->
          socket
          |> assign(:composer, %{text: "", parsed: nil, busy: false})
          |> push_event("voice:speak", %{text: started_line(parsed)})
          |> push_navigate(to: ~p"/s/#{session_id}")

        {:ok, {_parsed, {:error, reason}}} ->
          put_flash(socket, :error, "Could not start: #{format_error(reason)}")

        {:exit, reason} ->
          put_flash(socket, :error, "Could not start: #{inspect(reason)}")
      end

    {:halt, socket}
  end

  defp handle_async(_name, _result, socket), do: {:cont, socket}

  defp started_line(%{action: :run, project: p}), do: "Running #{spoken(p.name)}."

  defp started_line(%{project: p, skill: skill}),
    do: "Started in #{spoken(p.name)}#{if skill, do: " with #{spoken(skill)}"}."

  defp spoken(name), do: String.replace(name, ~r/[-_]+/, " ")

  @doc "Projects in sidebar order (projects, then routines); numbered 1–9 for shortcuts."
  def sidebar_order(projects) do
    Enum.filter(projects, &(&1.kind in ~w(code chat))) ++
      Enum.filter(projects, &(&1.kind in ~w(routine system)))
  end

  defp open_palette(socket, mode) do
    mode = if mode == "switch", do: "switch", else: "all"
    assign(socket, :palette, %{mode: mode, query: "", items: palette_items(socket, mode, "")})
  end

  # "switch" lists places only; "all" adds actions.
  defp palette_items(socket, mode, query) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.current_project
    prefs = socket.assigns.kb_prefs

    actions =
      if mode == "all" do
        [
          project &&
            %{
              label: "New session in #{project.name}",
              sub: "action",
              event: "palette_new_session",
              keys: Keybinds.new_session_keys(prefs)
            },
          project && project.kind == "routine" &&
            %{label: "Run #{project.name}", sub: "action", kb: "run", keys: ["mod+enter"]},
          %{label: "New project", sub: "action", to: ~p"/new"},
          %{label: "Toggle sidebar", sub: "action", kb: "zoom", keys: ["mod+\\"]},
          %{
            label: "Keyboard shortcuts",
            sub: "action",
            kb: "help",
            keys: Keybinds.help_keys(prefs)
          }
        ]
        |> Enum.filter(& &1)
      else
        []
      end

    tabs =
      Enum.map(
        socket.assigns.shell_tabs,
        &%{label: &1.title, sub: &1.project.name, to: ~p"/s/#{&1.id}"}
      )

    projects =
      socket.assigns.shell_projects
      |> sidebar_order()
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        %{
          label: p.name,
          sub: p.kind,
          to: ~p"/p/#{p.id}",
          keys: if(i < 9, do: Keybinds.item_keys(prefs, i))
        }
      end)

    pages =
      Enum.map(
        Keybinds.globals(user),
        &%{label: &1.name, sub: "page", to: &1.path, keys: Keybinds.global_keys(prefs, &1)}
      )

    q = String.downcase(String.trim(query))

    (actions ++ tabs ++ projects ++ pages)
    |> Enum.filter(&(q == "" or String.contains?(String.downcase(&1.label <> " " <> &1.sub), q)))
    |> Enum.take(12)
  end
end
