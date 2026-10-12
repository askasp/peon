defmodule Beamcode.TaskQueue do
  @moduledoc """
  A Code Folder's task queue, from `tk`: each tree (the Folder's main and every
  chat's worktree) has its own `.tickets/`, so a task belongs to the chat that
  owns the worktree and runs there, one at a time. A task on main starts in a
  new chat with a new worktree; its file moves there.

  Starting a task marks it in progress and sends the chat the task. The agent
  closes it with `tk close` when it's done; then, with `queue_auto` on, the
  worktree's next ready task starts (`finished/1`, from `TaskQueue.Runner`).
  """
  require Logger
  import Ecto.Query, only: [from: 2]
  alias Beamcode.{Opencode, Projects, Sessions, Tickets, Worktrees}
  alias Beamcode.Opencode.Events
  alias Beamcode.Projects.Project

  @doc """
  The queue: `%{auto, trees: [%{ref, worktree, chat, tickets}]}`. `ref` is
  "main" or the owning chat's id; `chat` is `%{id, title, status}` (nil for
  main). Main is always listed; a worktree only once it has tasks, or when it's
  `opts[:ref]` (a chat showing its own queue).
  """
  def board(%Project{} = project, user, opts \\ []) do
    with {:ok, sessions} <- Sessions.list_visible(project, user) do
      chats = owners(project, sessions)
      dirs = [project.directory | Enum.map(chats, & &1.dir)]
      found = Tickets.list_trees(project, dirs)

      main = %{
        ref: "main",
        worktree: "main",
        chat: nil,
        tickets: annotate(Map.get(found, project.directory, []))
      }

      trees =
        for c <- chats,
            tickets = Map.get(found, c.dir, []),
            tickets != [] or c.id == opts[:ref] do
          %{ref: c.id, worktree: Path.basename(c.dir), chat: chat(c), tickets: annotate(tickets)}
        end

      trees = with_runs(project, [main | trees])
      {:ok, %{auto: project.queue_auto, trees: trees}}
    end
  end

  # Each task's latest procedure run: where it is in its steps.
  defp with_runs(project, trees) do
    ids = for t <- trees, ticket <- t.tickets, do: ticket["id"]

    runs =
      from(r in Beamcode.Schedules.Run,
        where: r.project_id == ^project.id and r.ticket in ^ids,
        order_by: [asc: r.inserted_at]
      )
      |> Beamcode.Repo.all()
      |> Map.new(&{&1.ticket, &1})

    for t <- trees do
      %{t | tickets: Enum.map(t.tickets, &Map.put(&1, "run", run_json(runs[&1["id"]])))}
    end
  end

  defp run_json(nil), do: nil

  defp run_json(run) do
    %{
      id: run.id,
      procedure: run.procedure,
      status: run.status,
      step: run.step,
      waiting: run.waiting && run.waiting["text"],
      steps: Enum.map(run.steps, &Map.take(&1, ["name", "status", "model"]))
    }
  end

  # One chat per worktree folder: the one worked in last.
  defp owners(project, sessions) do
    sessions
    |> Enum.map(
      &%{id: &1["id"], title: &1["title"], dir: Sessions.session_dir(&1, project), s: &1}
    )
    |> Enum.reject(&(&1.dir == project.directory))
    |> Enum.group_by(& &1.dir)
    |> Enum.map(fn {_dir, list} ->
      Enum.max_by(list, &(get_in(&1.s, ["time", "updated"]) || 0))
    end)
    |> Enum.sort_by(&(get_in(&1.s, ["time", "updated"]) || 0), :desc)
  end

  defp chat(c), do: %{id: c.id, title: c.title || "New chat", status: Events.status(c.id)}

  # Which open deps hold a task back, and whether it was paused.
  defp annotate(tickets) do
    status = Map.new(tickets, &{&1["id"], &1["status"]})

    Enum.map(tickets, fn t ->
      t
      |> Map.put(
        "blocked_by",
        Enum.filter(t["deps"], &(Map.get(status, &1, "closed") != "closed"))
      )
      |> Map.put("paused", "paused" in t["tags"])
    end)
  end

  @doc """
  Adds tasks to the tree `ref`, from `titles`. With `chain`, each waits on the
  one before. `procedure:` names the procedure they run through (else the
  Folder's Queue default). Then, with `queue_auto`, an idle worktree starts
  the first. `{:ok, ids}`.
  """
  def add(%Project{} = project, user, ref, titles, chain \\ false, opts \\ []) do
    titles = titles |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == ""))

    with {:ok, tree} <- tree(project, user, ref),
         true <- titles != [] || {:error, "Say what the task is."},
         {:ok, ids} <- create_all(tree, titles) do
      if opts[:procedure] not in [nil, ""],
        do: Enum.each(ids, &Tickets.edit(tree, &1, %{"procedure" => opts[:procedure]}))

      if chain do
        ids
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [a, b] -> Tickets.dep(tree, b, a, true) end)
      end

      if ref not in [nil, "", "main"], do: continue(project, ref, tree.directory)
      {:ok, ids}
    end
  end

  defp create_all(tree, titles) do
    Enum.reduce_while(titles, {:ok, []}, fn title, {:ok, ids} ->
      case Tickets.create(tree, %{"title" => title}) do
        {:ok, %{"id" => id}} -> {:cont, {:ok, ids ++ [id]}}
        error -> {:halt, if(ids == [], do: error, else: {:ok, ids})}
      end
    end)
  end

  @doc """
  Starts task `id` in tree `ref`: in its worktree's chat when that chat is
  free, or, for a task on main, in a new chat with its own worktree.
  `{:ok, session_id}`.
  """
  def start(%Project{} = project, user, ref, id) when ref in [nil, "", "main"] do
    with {:ok, raw} <- Tickets.raw(project, id),
         ticket = Tickets.parse(raw),
         {:ok, session} <-
           Sessions.start(project, user, worktree: true, title: ticket["title"]) do
      dir = Sessions.session_dir(session, project)
      wt = %{project | directory: dir}

      with :ok <- Tickets.put(wt, id, raw),
           :ok <- Tickets.delete(project, id),
           :ok <- run(wt, session["id"], ticket, user) do
        {:ok, session["id"]}
      end
    end
  end

  def start(%Project{} = project, user, ref, id) do
    with {:ok, tree} <- tree(project, user, ref),
         {:ok, tickets} <- tickets(tree),
         %{} = ticket <- Enum.find(tickets, &(&1["id"] == id)) || {:error, "No task #{id}."} do
      running = Enum.find(tickets, &(&1["status"] == "in_progress" and &1["id"] != id))

      cond do
        running ->
          {:error, "#{running["id"]} is running here. #{id} can start after it."}

        Events.status(ref) != :idle ->
          {:error, "This chat is working. #{id} can start when it stops."}

        true ->
          with :ok <- run(tree, ref, ticket, user), do: {:ok, ref}
      end
    end
  end

  # Marks the task in progress and hands it to the chat: as a run of its
  # procedure (the ticket's, else the Folder's Queue default), else as one
  # message (`prompt/1`). A run closes the task when its last step is done.
  defp run(tree, session_id, ticket, user) do
    id = ticket["id"]

    with :ok <- Tickets.edit(tree, id, %{"paused" => false}),
         :ok <- Tickets.set_status(tree, id, "in_progress") do
      case procedure(tree, ticket) do
        nil ->
          with {:ok, _} <- Sessions.send_text(session_id, prompt(ticket), tree.directory), do: :ok

        proc ->
          user = user || owner(session_id)
          task = String.trim("#{ticket["title"]}\n\n#{ticket["body"]}")
          input = (Enum.at(proc.inputs, 0) || %{name: "task"}).name

          with {:ok, _run} <-
                 Beamcode.Procedures.Runs.start(tree, user, proc, %{input => task},
                   session_id: session_id,
                   trigger: "queue",
                   ticket: id
                 ),
               do: :ok
      end
    end
  end

  @doc "The procedure a task runs through: its own `procedure:`, else the Queue default."
  def procedure(tree, ticket) do
    list = Beamcode.Procedures.list(tree)

    case ticket["procedure"] do
      name when is_binary(name) and name != "" -> Enum.find(list, &(&1.name == name))
      _ -> Enum.find(list, &(&1.queue == "default"))
    end
  end

  defp owner(session_id) do
    case Projects.session_record(session_id) do
      %{user: %{} = user} -> user
      %{user_id: id} when is_integer(id) -> Beamcode.Accounts.get_user(id)
      _ -> nil
    end
  end

  @doc "What a chat is told when a task starts in it."
  def prompt(ticket) do
    body = if ticket["body"] in [nil, ""], do: "", else: "\n\n" <> ticket["body"]

    "Work on #{ticket["id"]}: #{ticket["title"]}#{body}\n\n" <>
      "When it's done and the tests pass, commit it in this worktree and run " <>
      "`tk close #{ticket["id"]}`. If you need me to decide something, ask and stop."
  end

  @doc "Pauses a running task: stops its chat and puts the task back, marked paused."
  def pause(%Project{} = project, user, ref, id) do
    with {:ok, tree} <- tree(project, user, ref) do
      if ref not in [nil, "", "main"], do: Opencode.interrupt(ref)

      with :ok <- Tickets.set_status(tree, id, "open"),
           :ok <- Tickets.edit(tree, id, %{"paused" => true}),
           do: Tickets.note(tree, id, "Paused. The work so far stays in the worktree.")
    end
  end

  @doc "Cancels a task: stops its chat if it's running and closes it in tk."
  def cancel(%Project{} = project, user, ref, id) do
    with {:ok, tree} <- tree(project, user, ref),
         {:ok, tickets} <- tickets(tree) do
      running? = Enum.any?(tickets, &(&1["id"] == id and &1["status"] == "in_progress"))
      if running? and ref not in [nil, "", "main"], do: Opencode.interrupt(ref)

      with :ok <- Tickets.set_status(tree, id, "closed"),
           do: Tickets.note(tree, id, "Cancelled.")
    end
  end

  @doc """
  Closes a task the chat stopped on without closing it (you checked it's
  done), then starts the worktree's next one as when the agent closes it.
  """
  def done(%Project{} = project, user, ref, id) do
    with {:ok, tree} <- tree(project, user, ref),
         :ok <- Tickets.set_status(tree, id, "closed") do
      if ref not in [nil, "", "main"], do: continue(project, ref, tree.directory)
      :ok
    end
  end

  @doc "The tree `ref` names, as a project with that `directory`."
  def tree(project, user, ref) do
    case Worktrees.at(project, user, ref) do
      {:ok, tree} -> {:ok, tree}
      {:error, :bad_ref} -> {:error, "That worktree is gone."}
    end
  end

  @doc """
  A chat stopped (OpenCode's session.execution.succeeded). If it's a Code
  Folder's worktree chat with `queue_auto` on and no task in progress there
  any more, start the next ready one.
  """
  def finished(session_id) do
    with %{} = info <- Events.session_info(session_id),
         %Project{kind: "code", queue_auto: true} = project <-
           Projects.project_for_session(info, Projects.list_projects()) do
      continue(project, session_id, Sessions.session_dir(info, project))
    end

    :ok
  rescue
    e -> Logger.error("task queue: " <> Exception.format(:error, e, __STACKTRACE__))
  end

  # The worktree's next ready task, when the chat is free and nothing runs.
  defp continue(%Project{queue_auto: true} = project, session_id, dir)
       when dir != project.directory do
    tree = %{project | directory: dir}

    with {:ok, tickets} <- tickets(tree),
         false <- Enum.any?(tickets, &(&1["status"] == "in_progress")),
         :idle <- Events.status(session_id),
         %{} = next <- tickets |> annotate() |> Enum.find(&ready?/1) do
      Logger.info("task queue: starting #{next["id"]} in #{Path.basename(dir)}")
      run(tree, session_id, next, nil)
    end
  end

  defp continue(_project, _session_id, _dir), do: :ok

  # One tree's tasks, in one shell call.
  defp tickets(tree),
    do: {:ok, Map.get(Tickets.list_trees(tree, [tree.directory]), tree.directory, [])}

  defp ready?(t), do: t["status"] == "open" and t["blocked_by"] == [] and not t["paused"]
end
