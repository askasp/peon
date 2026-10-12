defmodule Beamcode.Sessions do
  @moduledoc "Starting OpenCode sessions for a project and sending prompts to them."
  alias Beamcode.{BranchGuard, Opencode, Projects}
  alias Beamcode.Projects.Project

  @doc """
  Creates a session in the project's folder, or in a fresh git worktree when
  `worktree: true` in a Code Folder (other Folders have one tree), or on an
  existing branch with `branch: "name"` (its worktree, made when it has none).
  Records who started it.

  opts: :worktree, :branch, :scope, :schedule_key, :title, :agent, :model (%{"id", "providerID"})
  """
  def start(%Project{} = project, user, opts \\ []) do
    where =
      case opts[:branch] do
        b when is_binary(b) and b != "" and project.kind == "code" -> {:branch, b}
        _ -> Keyword.get(opts, :worktree, false)
      end

    with {:ok, dir} <- directory(project, where) do
      body =
        %{location: %{directory: dir}}
        |> put_opt(:title, opts[:title])
        |> put_opt(:agent, opts[:agent])
        |> put_opt(:model, opts[:model])
        |> put_rules(BranchGuard.session_rules(project))

      with {:ok, session} <- Opencode.create_session(body) do
        Projects.record_session(session["id"], project, user,
          scope: Keyword.get(opts, :scope, "team"),
          schedule_key: opts[:schedule_key]
        )

        {:ok, session}
      end
    end
  end

  @doc """
  Where new work in a Folder goes: its one chat in a single-chat Folder
  (`Project.single_chat?/1`), else a new session (`start/3`).
  """
  def open(%Project{} = project, user, opts \\ []) do
    if Project.single_chat?(project) do
      with {:ok, session, _earlier} <- folder_chat(project, user), do: {:ok, session}
    else
      start(project, user, opts)
    end
  end

  @doc """
  A single-chat Folder's one chat, made the first time: the team chat worked in
  last. Chats from before Folders had one chat come back as `earlier`, oldest
  first, so the app can show them above it under their old titles:
  `{:ok, session, earlier}`.
  """
  def folder_chat(%Project{} = project, user) do
    lock = {{__MODULE__, :folder_chat, project.id}, self()}
    :global.trans(lock, fn -> find_or_start_chat(project, user) end, [node()])
  end

  defp find_or_start_chat(project, user) do
    with {:ok, sessions} <- list_visible(project, user) do
      updated = &(get_in(&1, ["time", "updated"]) || 0)
      shared = Enum.reject(sessions, &match?(%{"record" => %{scope: "private"}}, &1))

      chat =
        case shared do
          [] -> start(project, user, title: project.name)
          list -> {:ok, Enum.max_by(list, updated)}
        end

      with {:ok, chat} <- chat do
        earlier =
          sessions
          |> Enum.reject(&(&1["id"] == chat["id"]))
          |> Enum.sort_by(&(get_in(&1, ["time", "created"]) || 0))

        {:ok, chat, earlier}
      end
    end
  end

  @doc """
  The project's top-level, unarchived sessions `user` may see, each with its
  record under `"record"`. On a routine, schedule runs are left out: they have
  their own list.
  """
  def list_visible(%Project{} = project, user) do
    params =
      if project.oc_project_id,
        do: [project: project.oc_project_id, limit: 150],
        else: [directory: project.directory, limit: 150]

    with {:ok, sessions} <- Opencode.list_sessions(params) do
      sessions = Enum.reject(sessions, &(&1["parentID"] || get_in(&1, ["time", "archived"])))
      records = Projects.session_records(Enum.map(sessions, & &1["id"]))

      {:ok,
       sessions
       |> Enum.filter(&Projects.session_visible?(records[&1["id"]], user))
       |> Enum.reject(&(project.kind == "routine" and run_record?(records[&1["id"]])))
       |> Enum.map(&Map.put(&1, "record", records[&1["id"]]))}
    end
  end

  defp run_record?(record), do: record != nil and record.schedule_key != nil

  @doc """
  The OpenCode session `id` with its project and record, when `user` may see it:
  `{:ok, session, project, record}` or `:error`.
  """
  def fetch_visible(id, user) do
    with {:ok, session} <- Opencode.get_session(id),
         %Project{} = project <-
           Projects.project_for_session(session, Projects.list_visible(user)),
         record = Projects.session_record(id),
         true <- Projects.session_visible?(record, user) do
      {:ok, session, project, record}
    else
      _ -> :error
    end
  end

  @doc "The folder a session works in."
  def session_dir(session, %Project{} = project),
    do: get_in(session, ["location", "directory"]) || project.directory

  @doc """
  Sessions that are running or waiting right now, in `projects` and visible to
  `user`: `%{id, title, project, status}`.
  """
  def running(user, projects) do
    ids = Opencode.Events.running_ids()
    records = Projects.session_records(ids)

    for id <- ids,
        info = Opencode.Events.session_info(id),
        info != nil,
        project = Projects.project_for_session(info, projects),
        project != nil,
        Projects.session_visible?(records[id], user) do
      %{
        id: id,
        title: info["title"] || "New session",
        project: project,
        status: Opencode.Events.status(id)
      }
    end
  end

  defp put_rules(map, []), do: map
  defp put_rules(map, rules), do: Map.put(map, :permissions, rules)

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, _key, ""), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp directory(project, false), do: {:ok, project.directory}
  defp directory(project, {:branch, branch}), do: Beamcode.Branches.directory(project, branch)

  defp directory(%Project{kind: kind} = project, true) when kind != "code",
    do: {:ok, project.directory}

  defp directory(%Project{oc_project_id: nil} = project, true),
    do: {:error, "#{project.name} has no OpenCode project id yet"}

  defp directory(project, true) do
    case Opencode.create_worktree(project.oc_project_id) do
      {:ok, %{"directory" => dir}} -> {:ok, dir}
      error -> error
    end
  end

  @doc """
  Sends text to a session. `/name rest` runs a skill or command called `name`
  when one exists in the session's folder; anything else is a plain prompt.
  `files` are `%{uri: "data:image/png;base64,…", name: "…"}` attachments.
  """
  def send_text(session_id, text, dir, files \\ [], delivery \\ nil) do
    text = String.trim(text)

    attach = fn body ->
      body = if files == [], do: body, else: Map.put(body, :files, files)
      if delivery, do: Map.put(body, :delivery, delivery), else: body
    end

    case Regex.run(~r{^/([\w.-]+)\s*(.*)$}s, text) do
      [_, name, rest] ->
        cond do
          skill?(dir, name) ->
            Opencode.prompt(
              session_id,
              attach.(%{
                text: if(rest == "", do: "Run the #{name} skill.", else: rest),
                skills: [%{id: name}]
              })
            )

          command?(dir, name) ->
            Opencode.command(session_id, attach.(%{name: name, text: rest}))

          true ->
            Opencode.prompt(session_id, attach.(%{text: text}))
        end

      _ ->
        Opencode.prompt(session_id, attach.(%{text: text}))
    end
  end

  defp skill?(dir, name) do
    case Opencode.skills(dir) do
      {:ok, skills} -> Enum.any?(skills, &(&1["id"] == name or &1["name"] == name))
      _ -> false
    end
  end

  defp command?(dir, name) do
    case Opencode.commands(dir) do
      {:ok, cmds} -> Enum.any?(cmds, &(&1["name"] == name))
      _ -> false
    end
  end

  @doc """
  Skills and commands available in a folder, for `/` completion.

  OpenCode loads a folder's skills and commands lazily: the first request for a
  folder answers with empty lists while it loads. So an empty answer is retried.
  """
  def slash_items(dir, tries \\ 5) do
    case {list(Opencode.skills(dir)), list(Opencode.commands(dir))} do
      {[], []} when tries > 1 ->
        Process.sleep(300)
        slash_items(dir, tries - 1)

      {skills, commands} ->
        skills =
          Enum.map(skills, &%{name: &1["id"], description: &1["description"], kind: "skill"})

        commands =
          Enum.map(
            commands,
            &%{name: &1["name"], description: &1["description"], kind: "command"}
          )

        Enum.reject(skills ++ commands, &(&1.name in ["opencode", "report"]))
    end
  end

  defp list({:ok, list}) when is_list(list), do: list
  defp list(_), do: []
end
