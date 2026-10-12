defmodule BeamcodeWeb.ProjectChannel do
  @moduledoc """
  One project for the app ("project:<id>"): its sessions, runs, skills,
  schedules and settings, through `Beamcode.ProjectTools`.

  Join replies `{project, can_edit, admin, inputs, routine}` (`inputs` is the routine's
  run form, or []).

  Requests:
    * `sessions` → `{sessions}`; `runs` → `{runs}`
    * `run` `{inputs?}` → `{session_id}` (routines)
    * `skills` → `{files}` (AGENTS.md first); `read_file` `{path}` → `{content}`;
      `save_file` `{path, content}`; `create_skill` `{name}` → `{path}`
    * `trees` → `{trees}`: the chats with a worktree that has changes
      (`[%{ref, title, worktree, changed}]`, see `Beamcode.Worktrees`)
    * `list_files` `{path}` → `{path, entries, base}`; `open_file` `{path}` →
      `{path, type, size, url, text}` (`text` is nil for binary or big files;
      `url` loads it under the signed `base`, see `BeamcodeWeb.FileToken`);
      `write_file` `{path, content}`; `table` `{path, table?}` → `{tables, table, columns, rows}`.
      Each takes `ref`: "main" (default) or a chat id for that chat's worktree.
      A Code Folder's own folder is read-only here: chats change it.
    * `schedules` → `{schedules, agents, models, blank}`; `describe_schedule` `{params}`
      → `{cron, when, next}`; `save_schedule` `{params}`; `delete_schedule` `{key}`;
      `run_schedule` `{key}` → `{session_id}`
    * `settings` → `{directory, skills, settings, github, connectors}`; `save_settings` `{params}` → `{project, message}`;
      `grant` `{connector, granted}`; `github_save` `{token}`; `github_remove`; `remove`

  Pushes `changed` when the project's sessions or runs change, so lists reload.
  """
  use BeamcodeWeb, :channel

  alias Beamcode.{
    Connectors,
    GitTokens,
    Projects,
    ProjectFiles,
    ProjectTools,
    Routines,
    Schedules,
    Sessions,
    Vault,
    Worktrees
  }

  alias Beamcode.Opencode.Events
  alias BeamcodeWeb.{AppJSON, ChannelTasks}

  # Text bigger than this is opened by URL instead of sent over the socket.
  @max_text 1_000_000

  # Only these files open in the editor: the instructions and the project's skills.
  @editable ~r{\A(AGENTS\.md|\.opencode/skill/[a-z0-9][a-z0-9-]*/SKILL\.md)\z}

  # AGENTS.md, a new skill's SKILL.md, or a skill file OpenCode lists for the
  # project (wherever it keeps them). Nothing else in the folder.
  defp editable?(project, path) do
    Regex.match?(@editable, path) or
      (not String.contains?(path, "..") and
         Enum.any?(ProjectTools.skill_files(project), fn {_name, p} -> p == path end))
  end

  @impl true
  def join("project:" <> _id, _params, %{assigns: %{user: nil}}),
    do: {:error, %{reason: "unauthorized"}}

  def join("project:" <> id, _params, socket) do
    user = socket.assigns.user

    case Enum.find(Projects.list_visible(user), &(to_string(&1.id) == id)) do
      nil ->
        {:error, %{reason: "not_found"}}

      project ->
        Events.subscribe_activity()
        Schedules.subscribe()
        Projects.subscribe()

        routine = if project.kind == "routine", do: Routines.config(project)

        {:ok,
         %{
           project: AppJSON.project(project),
           can_edit: ProjectTools.can_edit?(project, user),
           admin: user.admin,
           inputs:
             Enum.map(
               (routine && routine.inputs) || [],
               &Map.take(&1, [:name, :default, :options, :multi])
             ),
           # What a run does, and what's wrong with routine.json if anything.
           routine: routine && %{run: routine.run, error: routine.error}
         }, assign(socket, project: project, changed_ref: nil, tasks: %{})}
    end
  end

  ## Sessions and runs

  @impl true
  def handle_in("sessions", _params, socket) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      case Sessions.list_visible(project, user) do
        {:ok, sessions} ->
          sessions = Enum.sort_by(sessions, &(get_in(&1, ["time", "updated"]) || 0), :desc)
          {:ok, %{sessions: Enum.map(sessions, &AppJSON.listed_session(&1, project))}}

        {:error, reason} ->
          error(reason)
      end
    end)
  end

  def handle_in("runs", _params, socket) do
    user = socket.assigns.user

    # Like the web: team runs, and your own private ones.
    runs =
      socket.assigns.project.id
      |> Schedules.project_runs(100)
      |> Enum.filter(&(&1.scope == "team" or &1.owner_id == user.id))

    {:reply, {:ok, %{runs: Enum.map(runs, &AppJSON.run/1)}}, socket}
  end

  def handle_in("run", params, socket) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      config = Routines.config(project)

      case Routines.run(project, user, inputs(params["inputs"], config)) do
        {:ok, run} -> {:ok, %{session_id: run.session_id}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  ## Skills and files

  def handle_in("skills", _params, socket) do
    project = socket.assigns.project

    ChannelTasks.reply_async(socket, fn ->
      skills =
        for {name, path} <- ProjectTools.skill_files(project), do: %{name: name, path: path}

      {:ok, %{files: [%{name: "AGENTS.md", path: "AGENTS.md"} | skills]}}
    end)
  end

  def handle_in("read_file", %{"path" => path}, socket) when is_binary(path) do
    project = socket.assigns.project

    ChannelTasks.reply_async(socket, fn ->
      if editable?(project, path),
        do: {:ok, %{path: path, content: ProjectTools.read_file(project, path)}},
        else: {:error, %{message: "That file can't be opened here."}}
    end)
  end

  def handle_in("save_file", %{"path" => path, "content" => content}, socket)
      when is_binary(path) and is_binary(content) do
    project = socket.assigns.project

    ChannelTasks.reply_async(socket, fn ->
      with true <- editable?(project, path),
           :ok <- ProjectTools.write_file(project, path, content) do
        {:ok, %{}}
      else
        false -> {:error, %{message: "That file can't be saved here."}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("trees", _params, socket) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      case Worktrees.list(project, user) do
        {:ok, trees} -> {:ok, %{trees: trees}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("list_files", %{"path" => path} = params, socket) when is_binary(path) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      with {:ok, project} <- Worktrees.at(project, user, params["ref"]),
           {:ok, entries} <- ProjectFiles.list(project, path) do
        {:ok, clean} = ProjectFiles.clean_path(path)
        {:ok, %{path: clean, entries: entries, base: BeamcodeWeb.FileToken.base(user, project)}}
      else
        {:error, reason} -> file_error(reason)
      end
    end)
  end

  def handle_in("open_file", %{"path" => path} = params, socket) when is_binary(path) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      with {:ok, project} <- Worktrees.at(project, user, params["ref"]),
           {:ok, body} <- ProjectFiles.read(project, path) do
        {:ok, clean} = ProjectFiles.clean_path(path)

        text =
          if byte_size(body) <= @max_text and ProjectFiles.text?(body), do: body

        {:ok,
         %{
           path: clean,
           type: ProjectFiles.content_type(clean),
           size: byte_size(body),
           url: BeamcodeWeb.FileToken.base(user, project) <> URI.encode(clean),
           text: text
         }}
      else
        {:error, reason} -> file_error(reason)
      end
    end)
  end

  def handle_in("write_file", %{"path" => path, "content" => content} = params, socket)
      when is_binary(path) and is_binary(content) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      with {:ok, tree} <- Worktrees.at(project, user, params["ref"]),
           false <- Worktrees.code_main?(tree, project),
           :ok <- ProjectFiles.write(tree, path, content) do
        {:ok, %{}}
      else
        true -> file_error(:read_only)
        {:error, reason} -> file_error(reason)
      end
    end)
  end

  def handle_in("table", %{"path" => path} = params, socket) when is_binary(path) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      with {:ok, project} <- Worktrees.at(project, user, params["ref"]),
           {:ok, data} <- ProjectFiles.table(project, path, params["table"]) do
        {:ok, data}
      else
        {:error, reason} -> file_error(reason)
      end
    end)
  end

  def handle_in("create_skill", %{"name" => name}, socket) when is_binary(name) do
    project = socket.assigns.project

    ChannelTasks.reply_async(socket, fn ->
      case ProjectTools.create_skill(project, name) do
        {:ok, path} -> {:ok, %{path: path}}
        {:error, msg} -> {:error, %{message: msg}}
      end
    end)
  end

  ## Schedules

  def handle_in("schedules", _params, socket) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      case ProjectTools.schedules(project, user) do
        {:ok, list} ->
          {:ok,
           %{
             schedules:
               Enum.map(list, fn s ->
                 s
                 |> AppJSON.schedule()
                 |> Map.put(:params, ProjectTools.params_from_schedule(s))
                 # Its last five runs, newest first.
                 |> Map.put(:runs, Enum.map(Schedules.runs(project.id, s.key, 5), &AppJSON.run/1))
               end),
             agents: ProjectTools.agents(project),
             models: for({value, name} <- ProjectTools.models(), do: %{value: value, name: name}),
             blank: ProjectTools.new_schedule_params(user)
           }}

        {:error, msg} ->
          {:error, %{message: msg}}
      end
    end)
  end

  def handle_in("describe_schedule", %{"params" => params}, socket) when is_map(params) do
    {cron, description, next} = ProjectTools.describe_schedule(params)

    {:reply,
     {:ok, %{cron: cron, when: description, next: next && NaiveDateTime.to_iso8601(next)}},
     socket}
  end

  def handle_in("save_schedule", %{"params" => params}, socket) when is_map(params) do
    %{project: project, user: user} = socket.assigns

    # Schedules.save checks the name, the cron line and the prompt.
    ChannelTasks.reply_async(socket, fn ->
      case ProjectTools.save_schedule(project, Map.put_new(params, "key", ""), user) do
        :ok -> {:ok, %{}}
        {:error, msg} -> {:error, %{message: msg}}
      end
    end)
  end

  def handle_in("delete_schedule", %{"key" => key}, socket) when is_binary(key) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      case ProjectTools.delete_schedule(project, key, user) do
        :ok -> {:ok, %{}}
        {:error, msg} -> {:error, %{message: msg}}
      end
    end)
  end

  def handle_in("run_schedule", %{"key" => key}, socket) when is_binary(key) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      with {:ok, list} <- ProjectTools.schedules(project, user),
           %{raw: raw} <- Enum.find(list, &(&1.key == key)),
           {:ok, run} <- Schedules.run(project, key, raw) do
        {:ok, %{session_id: run.session_id}}
      else
        nil -> {:error, %{message: "No schedule called #{key}."}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  ## Settings

  def handle_in("settings", _params, socket) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn -> {:ok, settings(project, user)} end)
  end

  def handle_in("save_settings", %{"params" => params}, socket) when is_map(params) do
    params = Map.take(params, ["scope", "always_worktree", "protect_default_branch"])

    case ProjectTools.update_settings(socket.assigns.project, params, socket.assigns.user) do
      {result, project, msg} when result in [:ok, :reverted] ->
        reply = %{project: AppJSON.project(project), message: msg, reverted: result == :reverted}
        {:reply, {:ok, reply}, assign(socket, project: project)}

      {:error, msg} ->
        {:reply, {:error, %{message: msg}}, socket}
    end
  end

  def handle_in("grant", %{"connector" => name, "granted" => granted}, socket)
      when is_binary(name) and is_boolean(granted) do
    %{project: project, user: user} = socket.assigns

    if user.admin do
      ChannelTasks.reply_async(socket, fn ->
        Connectors.set_granted(name, project.name, granted)
        Connectors.sync_all()
        {:ok, settings(project, user)}
      end)
    else
      {:reply, {:error, %{message: "Admins grant connectors."}}, socket}
    end
  end

  def handle_in("github_save", %{"token" => token}, socket) when is_binary(token) do
    %{project: project, user: user} = socket.assigns

    if ProjectTools.can_edit?(project, user) do
      ChannelTasks.reply_async(
        socket,
        fn ->
          case GitTokens.save(project, token, user) do
            {:ok, project} -> {:saved, project}
            {:error, reason} -> error(reason)
          end
        end,
        fn
          {:saved, project}, socket ->
            {{:ok, %{repo: project.github_repo}}, assign(socket, project: project)}

          reply, socket ->
            {reply, socket}
        end
      )
    else
      {:reply, {:error, %{message: "Only the owner or an admin can change this."}}, socket}
    end
  end

  def handle_in("github_remove", _params, socket) do
    %{project: project, user: user} = socket.assigns

    if ProjectTools.can_edit?(project, user) do
      ChannelTasks.reply_async(socket, fn ->
        case GitTokens.delete(project) do
          :ok ->
            {:ok, %{}}

          error ->
            {:error,
             %{
               message:
                 "Removed from the vault, but not from the server: #{ChannelTasks.error_message(error)}"
             }}
        end
      end)
    else
      {:reply, {:error, %{message: "Only the owner or an admin can change this."}}, socket}
    end
  end

  def handle_in("remove", _params, socket) do
    %{project: project, user: user} = socket.assigns

    if user.admin and project.kind != "system" do
      {:ok, _} = Projects.delete_project(project)

      # Keyed by name, so a later project with the same name must not inherit it.
      if project.kind == "code",
        do:
          Task.Supervisor.start_child(Beamcode.TaskSupervisor, fn -> GitTokens.delete(project) end)

      {:reply, {:ok, %{}}, socket}
    else
      {:reply, {:error, %{message: "Admins only."}}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{message: "Unknown request."}}, socket}

  ## Pushes

  @impl true
  def handle_info({:oc_activity, _type, _data}, socket), do: {:noreply, changed(socket)}
  def handle_info({:runs_changed, _}, socket), do: {:noreply, changed(socket)}

  def handle_info(
        {:project_changed, %{id: id}},
        %{assigns: %{project: %{id: id}}} = socket
      ) do
    # Access is checked again: a project made private or removed closes for
    # those who can't see it any more.
    case ChannelTasks.still_visible(id, socket.assigns.user) do
      {:ok, project} ->
        push(socket, "project", %{project: AppJSON.project(project)})
        {:noreply, assign(socket, project: project)}

      :gone ->
        push(socket, "gone", %{})
        {:stop, :normal, socket}
    end
  end

  def handle_info(:changed, socket) do
    push(socket, "changed", %{})
    {:noreply, assign(socket, changed_ref: nil)}
  end

  def handle_info({ref, _} = msg, socket) when is_reference(ref),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info({:DOWN, _, :process, _, _} = msg, socket),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  defp changed(%{assigns: %{changed_ref: nil}} = socket),
    do: assign(socket, changed_ref: Process.send_after(self(), :changed, 400))

  defp changed(socket), do: socket

  defp settings(project, user) do
    {connectors, secrets} =
      if Beamcode.Workspace.uses_gateway?(project) and project.kind != "system",
        do: {Connectors.list() |> Enum.filter(&(&1.error == nil)), Vault.names()},
        else: {[], MapSet.new()}

    %{
      directory: project.directory,
      skills:
        for({name, path} <- ProjectTools.skill_files(project), do: %{name: name, path: path}),
      settings: %{
        scope: project.scope,
        always_worktree: project.always_worktree,
        protect_default_branch: project.protect_default_branch
      },
      github:
        if(project.kind == "code",
          do: %{repo: project.github_repo, hint: GitTokens.hint(project)}
        ),
      connectors:
        for c <- connectors do
          %{
            name: c.name,
            tools: length(c.tools),
            ready: Connectors.ready?(c, secrets),
            granted: project.name in c.projects
          }
        end,
      can_edit: ProjectTools.can_edit?(project, user),
      admin: user.admin
    }
  end

  # Form values for the routine's inputs; multi-choice inputs are lists.
  defp inputs(values, config) when is_map(values) do
    Map.new(config.inputs, fn input ->
      value = Map.get(values, input.name, input.default)
      value = if input.multi, do: value |> List.wrap() |> Enum.reject(&(&1 == "")), else: value
      {input.name, value}
    end)
  end

  defp inputs(_, _config), do: %{}

  defp error(reason), do: {:error, %{message: ChannelTasks.error_message(reason)}}

  defp file_error(:bad_path), do: {:error, %{message: "That path is outside the folder."}}
  defp file_error(:enoent), do: {:error, %{message: "Not found."}}
  defp file_error(:too_big), do: {:error, %{message: "Too big to open."}}
  defp file_error(:bad_ref), do: {:error, %{message: "That chat's files aren't available."}}

  defp file_error(:read_only),
    do: {:error, %{message: "Main is read-only here. Edit in a chat's worktree, or ask a chat."}}

  defp file_error(reason), do: error(reason)
end
