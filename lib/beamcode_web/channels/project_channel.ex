defmodule BeamcodeWeb.ProjectChannel do
  @moduledoc """
  One project for the app ("project:<id>"): its sessions, runs, skills,
  schedules and settings, through `Beamcode.ProjectTools`.

  Join replies `{project, can_edit, admin, procedures, procedures_error}`
  (a Procedure Folder's procedures, see `Beamcode.Routines.list/1`; else []).

  Requests:
    * `sessions` → `{sessions}`; `runs` → `{runs}`
    * `tickets` → `{tickets}`: the Folder's `tk` tasks. `ticket_create`
      `{params}` queues one, `ticket_status` `{id, status}` moves it, and
      `ticket_note` `{id, text}` adds progress; each replies with `{tickets}`
    * `queue` `{view?}` → `{queue}`: a Code Folder's tasks by tree (see
      `Beamcode.TaskQueue.board/3`; `view` is a chat whose tree to list even
      when empty). `queue_add` `{ref, titles, chain?}`, `queue_start`,
      `queue_pause`, `queue_cancel`, `queue_done`, `queue_delete` `{ref, id}`, `queue_edit`
      `{ref, id, params}`, `queue_dep` `{ref, id, dep, on}` and `queue_auto`
      `{on}` each reply with `{queue}` (and `ids` / `session_id`)
    * `procedures` → `{procedures, error}`
    * `run` `{procedure?, inputs? | rows?}` → `{session_id}`: runs a procedure in
      the Folder's chat, once with `inputs` or once per row of `rows` (one message)
    * `run_result` `{id}` → `{text}`: a run's result, to show it in the Folder's chat
    * `skills` → `{files}` (AGENTS.md first); `read_file` `{path}` → `{content}`;
      `save_file` `{path, content}`; `create_skill` `{name}` → `{path}`
    * `slash` → `{slash}`: skills and commands for `/` completion (`Sessions.slash_items/2`)
    * `branches` → `{branches}`: git branches a new chat can continue (`Beamcode.Branches`)
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
    * `sources` → `{sources, connectors}`: a Dataset's synced sources with their
      action levels and local columns; `source_add` `{connector, choice}`;
      `source_level` `{name, action, level}`; `source_remove` `{name}`
    * `outbox` → `{entries}`; `outbox_post` `{id, args?}`, `outbox_skip`, `outbox_undo`,
      `outbox_retry` `{id}` (see `Beamcode.Outbox`)
    * `settings` → `{directory, skills, settings, github, connectors}`; `save_settings` `{params}` → `{project, message}`;
      `grant` `{connector, granted}`; `github_save` `{token}`; `github_remove`; `remove`

  Pushes `changed` when the project's sessions or runs change, so lists reload.
  """
  use BeamcodeWeb, :channel

  alias Beamcode.{
    Connectors,
    DataSources,
    GitTokens,
    Opencode,
    Outbox,
    Projects,
    ProjectFiles,
    ProjectTools,
    Routines,
    Schedules,
    Sessions,
    TaskQueue,
    Tickets,
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

        {procedures, error} = procedures(project)

        {:ok,
         %{
           project: AppJSON.project(project),
           can_edit: ProjectTools.can_edit?(project, user),
           admin: user.admin,
           procedures: procedures,
           procedures_error: error
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

  # A single-chat Folder's one chat, and the chats it had before (see
  # Sessions.folder_chat/2).
  def handle_in("folder_chat", _params, socket) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      case Sessions.folder_chat(project, user) do
        {:ok, chat, earlier} ->
          {:ok,
           %{
             session_id: chat["id"],
             earlier: Enum.map(earlier, &AppJSON.listed_session(&1, project))
           }}

        {:error, reason} ->
          error(reason)
      end
    end)
  end

  # The messages of an earlier chat in this Folder, shown above its one chat.
  def handle_in("chat_history", %{"session_id" => sid}, socket) when is_binary(sid) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      with {:ok, _session, %{id: id}, _record} when id == project.id <-
             Sessions.fetch_visible(sid, user),
           {:ok, messages} <- Opencode.messages(sid) do
        {:ok, %{messages: Enum.map(messages, &AppJSON.message/1)}}
      else
        {:error, reason} -> error(reason)
        _ -> error("That chat isn't in this Folder.")
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

  def handle_in("procedures", _params, socket) do
    project = socket.assigns.project

    ChannelTasks.reply_async(socket, fn ->
      {procedures, error} = procedures(project)
      {:ok, %{procedures: procedures, error: error}}
    end)
  end

  def handle_in("run", params, socket) do
    %{project: project, user: user} = socket.assigns

    values =
      case params["rows"] do
        rows when is_list(rows) and rows != [] -> for r <- rows, is_map(r), do: values(r)
        _ -> values(params["inputs"])
      end

    ChannelTasks.reply_async(socket, fn ->
      case Routines.run(project, user, values, params["procedure"]) do
        {:ok, session_id} -> {:ok, %{session_id: session_id}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("run_result", %{"id" => id}, socket) do
    %{project: project, user: user} = socket.assigns

    case Enum.find(Schedules.project_runs(project.id), &(to_string(&1.id) == to_string(id))) do
      %{session_id: sid, scope: scope, owner_id: owner}
      when is_binary(sid) and (scope == "team" or owner == user.id) ->
        ChannelTasks.reply_async(socket, fn ->
          case Schedules.result(sid) do
            {:ok, text} -> {:ok, %{text: text}}
            {:error, reason} -> error(reason)
          end
        end)

      _ ->
        {:reply, {:error, %{message: "No such run here."}}, socket}
    end
  end

  ## Tasks (tk tickets in the Folder's .tickets/)

  def handle_in("tickets", _params, socket) do
    project = socket.assigns.project
    ChannelTasks.reply_async(socket, fn -> ticket_reply(project) end)
  end

  def handle_in("ticket_create", %{"params" => params}, socket) when is_map(params) do
    ticket_edit(socket, &Tickets.create(&1, params))
  end

  def handle_in("ticket_status", %{"id" => id, "status" => status}, socket)
      when is_binary(id) and is_binary(status) do
    ticket_edit(socket, &Tickets.set_status(&1, id, status))
  end

  def handle_in("ticket_note", %{"id" => id, "text" => text}, socket)
      when is_binary(id) and is_binary(text) do
    ticket_edit(socket, &Tickets.note(&1, id, text))
  end

  ## Queue (tk tasks by worktree, Code Folders)

  def handle_in("queue", params, socket) do
    %{project: project, user: user} = socket.assigns
    ChannelTasks.reply_async(socket, fn -> queue_reply(project, user, params, %{}) end)
  end

  def handle_in("queue_add", %{"ref" => ref, "titles" => titles} = params, socket)
      when is_binary(ref) and is_list(titles) do
    queue_edit(socket, params, fn project, user ->
      with {:ok, ids} <- TaskQueue.add(project, user, ref, titles, params["chain"] == true),
           do: {:ok, %{ids: ids}}
    end)
  end

  def handle_in("queue_start", %{"ref" => ref, "id" => id} = params, socket)
      when is_binary(ref) and is_binary(id) do
    queue_edit(socket, params, fn project, user ->
      with {:ok, sid} <- TaskQueue.start(project, user, ref, id), do: {:ok, %{session_id: sid}}
    end)
  end

  def handle_in("queue_pause", %{"ref" => ref, "id" => id} = params, socket)
      when is_binary(ref) and is_binary(id),
      do: queue_edit(socket, params, &TaskQueue.pause(&1, &2, ref, id))

  def handle_in("queue_done", %{"ref" => ref, "id" => id} = params, socket)
      when is_binary(ref) and is_binary(id),
      do: queue_edit(socket, params, &TaskQueue.done(&1, &2, ref, id))

  def handle_in("queue_cancel", %{"ref" => ref, "id" => id} = params, socket)
      when is_binary(ref) and is_binary(id),
      do: queue_edit(socket, params, &TaskQueue.cancel(&1, &2, ref, id))

  def handle_in("queue_delete", %{"ref" => ref, "id" => id} = params, socket)
      when is_binary(ref) and is_binary(id) do
    queue_edit(socket, params, fn project, user ->
      with {:ok, tree} <- TaskQueue.tree(project, user, ref), do: Tickets.delete(tree, id)
    end)
  end

  def handle_in("queue_edit", %{"ref" => ref, "id" => id, "params" => attrs} = params, socket)
      when is_binary(ref) and is_binary(id) and is_map(attrs) do
    attrs = Map.take(attrs, ["title", "body", "priority"])

    queue_edit(socket, params, fn project, user ->
      with {:ok, tree} <- TaskQueue.tree(project, user, ref), do: Tickets.edit(tree, id, attrs)
    end)
  end

  def handle_in(
        "queue_dep",
        %{"ref" => ref, "id" => id, "dep" => dep, "on" => on} = params,
        socket
      )
      when is_binary(ref) and is_binary(id) and is_binary(dep) and is_boolean(on) do
    queue_edit(socket, params, fn project, user ->
      with {:ok, tree} <- TaskQueue.tree(project, user, ref), do: Tickets.dep(tree, id, dep, on)
    end)
  end

  def handle_in("queue_auto", %{"on" => on} = params, socket) when is_boolean(on) do
    %{project: project, user: user} = socket.assigns

    case ProjectTools.update_settings(project, %{"queue_auto" => on}, user) do
      {:ok, project, _msg} ->
        socket = assign(socket, project: project)
        ChannelTasks.reply_async(socket, fn -> queue_reply(project, user, params, %{}) end)

      {_, _project, msg} ->
        {:reply, {:error, %{message: msg}}, socket}

      {:error, msg} ->
        {:reply, {:error, %{message: msg}}, socket}
    end
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

  # The Folder's skills and commands, for `/` completion in the new-chat box.
  def handle_in("slash", _params, socket) do
    project = socket.assigns.project

    ChannelTasks.reply_async(socket, fn ->
      {:ok, %{slash: Sessions.slash_items(project.directory, 2)}}
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

  def handle_in("branches", _params, socket) do
    project = socket.assigns.project

    ChannelTasks.reply_async(socket, fn ->
      case Beamcode.Branches.list(project) do
        {:ok, branches} -> {:ok, %{branches: branches}}
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
        {:ok, clean} = ProjectFiles.clean_path(path)

        # A synced table's own columns (notes…) are marked local in the view.
        local =
          case Enum.find(DataSources.connector_sources(project), fn {_, s} ->
                 s.table == data.table and s.db == clean
               end) do
            {name, s} -> DataSources.local_columns(project, name, s)
            nil -> []
          end

        {:ok,
         Map.merge(data, %{
           sources: DataSources.list(project, clean),
           local: local,
           can_refresh: ProjectTools.can_edit?(project, user)
         })}
      else
        {:error, reason} -> file_error(reason)
      end
    end)
  end

  # Runs a dataset source's script again (sources.json), without the agent.
  def handle_in("refresh_source", %{"name" => name}, socket) when is_binary(name) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      if ProjectTools.can_edit?(project, user) do
        case DataSources.refresh(project, name) do
          :ok -> {:ok, %{}}
          {:error, reason} -> error(reason)
        end
      else
        error("Only the folder's owner can refresh its sources.")
      end
    end)
  end

  ## Synced sources and the Outbox

  def handle_in("sources", _params, socket) do
    %{project: project, user: user} = socket.assigns
    ChannelTasks.reply_async(socket, fn -> {:ok, sources(project, user)} end)
  end

  def handle_in("source_add", %{"connector" => id} = params, socket) when is_binary(id) do
    edit(socket, fn project ->
      with {:ok, name} <- DataSources.add(project, id, params["choice"]) do
        # The first sync's error shows on the source; the source is added either way.
        _ = DataSources.refresh(project, name)
        :ok
      end
    end)
  end

  def handle_in("source_level", %{"name" => name, "action" => action, "level" => level}, socket)
      when is_binary(name) and is_binary(action) and is_binary(level) do
    edit(socket, &DataSources.set_level(&1, name, action, level))
  end

  def handle_in("source_remove", %{"name" => name}, socket) when is_binary(name) do
    edit(socket, &DataSources.remove(&1, name))
  end

  def handle_in("outbox", params, socket) do
    project = socket.assigns.project
    db = params["db"] || "data.sqlite"
    ChannelTasks.reply_async(socket, fn -> {:ok, %{entries: Outbox.list(project, db)}} end)
  end

  def handle_in("outbox_" <> op, %{"id" => id} = params, socket)
      when op in ~w(post skip undo retry) and is_integer(id) do
    project = socket.assigns.project
    db = params["db"] || "data.sqlite"

    ChannelTasks.reply_async(socket, fn ->
      result =
        case op do
          "post" ->
            Outbox.approve(project, db, id, if(is_map(params["args"]), do: params["args"]))

          "skip" ->
            Outbox.skip(project, db, id)

          "undo" ->
            Outbox.undo(project, db, id)

          "retry" ->
            Outbox.retry(project, db, id)
        end

      case result do
        {:error, reason} -> error(reason)
        _ -> {:ok, %{entries: Outbox.list(project, db)}}
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
    params =
      Map.take(params, ["scope", "always_worktree", "protect_default_branch", "queue_auto"])

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

  # A procedure's inputs from the app: strings, and lists for multi-choice ones.
  defp values(map) when is_map(map) do
    for {k, v} <- map, is_binary(k), into: %{} do
      if is_list(v),
        do: {k, v |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))},
        else: {k, to_string(v)}
    end
  end

  defp values(_), do: %{}

  defp procedures(%{kind: "routine"} = project) do
    list =
      for p <- Routines.list(project) do
        Map.take(p, [:name, :description, :inputs, :key])
      end

    {list, Routines.error(project)}
  end

  defp procedures(_project), do: {[], nil}

  # The Folder's tasks, to reply after any change.
  defp ticket_reply(project) do
    {:ok, tickets} = Tickets.list(project)
    {:ok, %{tickets: tickets}}
  end

  # A change to the Folder's tasks (owners and admins), replying with the new list.
  defp ticket_edit(socket, fun) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      if ProjectTools.can_edit?(project, user) do
        case fun.(project) do
          {:error, reason} -> error(reason)
          _ -> ticket_reply(project)
        end
      else
        error("Only the folder's owner can change its tasks.")
      end
    end)
  end

  defp queue_reply(project, user, params, extra) do
    view = if is_binary(params["view"]), do: params["view"]

    case TaskQueue.board(project, user, ref: view) do
      {:ok, board} -> {:ok, Map.put(extra, :queue, board)}
      {:error, reason} -> error(reason)
    end
  end

  # A change to the Folder's queue (owners and admins), replying with the new
  # queue. `fun` gets the project and user: `:ok`, `{:ok, extra}` or an error.
  defp queue_edit(socket, params, fun) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      if ProjectTools.can_edit?(project, user) do
        case fun.(project, user) do
          :ok -> queue_reply(project, user, params, %{})
          {:ok, extra} when is_map(extra) -> queue_reply(project, user, params, extra)
          {:error, reason} -> error(reason)
          other -> error(inspect(other))
        end
      else
        error("Only the folder's owner can change its tasks.")
      end
    end)
  end

  # A change to the Folder's sources (owners and admins), replying with the new list.
  defp edit(socket, fun) do
    %{project: project, user: user} = socket.assigns

    ChannelTasks.reply_async(socket, fn ->
      if ProjectTools.can_edit?(project, user) do
        case fun.(project) do
          {:error, reason} -> error(reason)
          _ -> {:ok, sources(project, user)}
        end
      else
        error("Only the folder's owner can change its sources.")
      end
    end)
  end

  defp sources(project, user) do
    listed = DataSources.list(project) |> Enum.filter(&Map.has_key?(&1, :connector))
    connected = DataSources.connector_sources(project)

    %{
      sources:
        for src <- listed, s = connected[src.name] do
          info = s.connector.info()

          Map.merge(src, %{
            actions:
              for {name, a} <- Enum.sort(info.actions) do
                %{name: name, label: a.label, level: DataSources.level(s, name)}
              end,
            local_columns: DataSources.local_columns(project, src.name, s)
          })
        end,
      connectors: DataSources.connector_list(),
      can_edit: ProjectTools.can_edit?(project, user)
    }
  end

  defp error(reason), do: {:error, %{message: ChannelTasks.error_message(reason)}}

  defp file_error(:bad_path), do: {:error, %{message: "That path is outside the folder."}}
  defp file_error(:enoent), do: {:error, %{message: "Not found."}}
  defp file_error(:too_big), do: {:error, %{message: "Too big to open."}}
  defp file_error(:bad_ref), do: {:error, %{message: "That chat's files aren't available."}}

  defp file_error(:read_only),
    do: {:error, %{message: "Main is read-only here. Edit in a chat's worktree, or ask a chat."}}

  defp file_error(reason), do: error(reason)
end
