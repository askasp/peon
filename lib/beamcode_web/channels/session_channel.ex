defmodule BeamcodeWeb.SessionChannel do
  @moduledoc """
  One session for the app ("session:<id>"), fed by the OpenCode events
  (`Beamcode.Opencode.Events`).

  Join replies `{session, project, messages, status, perms, run, diff}`.

  Requests:
    * `send` `{text, files?}` – files are `[{uri: "data:image/…;base64,…", name}]`
    * `interrupt`, `compact`, `rename` `{title}`, `run_again` → `{session_id}`
    * `permission` `{id, decision}` (once | always | reject)
    * `options` → `{agents, models, slash}` for the pickers and `/` completion
    * `set_model` `{model: "provider/id"}`, `set_agent` `{agent}`
    * `find_files` `{query}` → `{items}` for `@` completion ("" lists the top folder)
    * `messages` (all of them again)
    * `image` `{message_id, index}` → `{mime, data}`, a pasted image too big to come with its message

  Pushes:
    * `delta` `{message_id, kind, delta}` – streamed text ("text" or "reasoning")
    * `messages` `{upsert, ids}` – stored messages that changed, and the order of all of them
    * `status` `{status, perms}` – idle | running | waiting, and pending permission requests
    * `session` `{session}` – renamed, or model/agent switched
    * `run` `{run}` – the routine run this session is, when it starts or finishes
    * `diff` `{files}` – changed files (`file`, `additions`, `deletions`, `patch`), when they change
    * `speak` `{text}` – a short line to say: the reply when a turn ends, or a permission ask
  """
  use BeamcodeWeb, :channel

  alias Beamcode.{Inbox, Opencode, Schedules, Sessions, Speech}
  alias Beamcode.Opencode.Events
  alias BeamcodeWeb.{AppJSON, ChannelTasks}

  @refetch_after 120
  @decisions ~w(once always reject)

  @impl true
  def join("session:" <> _id, _params, %{assigns: %{user: nil}}),
    do: {:error, %{reason: "unauthorized"}}

  def join("session:" <> id, _params, socket) do
    case Sessions.fetch_visible(id, socket.assigns.user) do
      {:ok, session, project, record} ->
        Events.subscribe_session(id)
        Schedules.subscribe()
        Beamcode.Projects.subscribe()

        socket =
          socket
          |> assign(
            session_id: id,
            session: session,
            project: project,
            record: record,
            sent: %{},
            refetch_ref: nil,
            speak_next: nil,
            status: Events.status(id),
            diff: [],
            tasks: %{}
          )

        {messages, socket} = load_messages(socket)
        socket = assign(socket, diff: load_diff(id))

        {:ok,
         %{
           session: session_json(session, project, record),
           project: AppJSON.project(project),
           messages: messages,
           status: socket.assigns.status,
           perms: perms(id),
           run: run(id),
           diff: socket.assigns.diff
         }, socket}

      :error ->
        {:error, %{reason: "not_found"}}
    end
  end

  ## Requests

  @impl true
  def handle_in("send", %{"text" => text} = params, socket) when is_binary(text) do
    files =
      for %{"uri" => "data:image/" <> _ = uri} = f <- List.wrap(params["files"]),
          do: %{uri: uri, name: f["name"] || "image.png"}

    if String.trim(text) == "" and files == [] do
      {:reply, {:error, %{message: "Nothing to send."}}, socket}
    else
      %{session_id: sid, session: session, project: project} = socket.assigns
      dir = Sessions.session_dir(session, project)
      # While a run works, follow-ups wait for it instead of steering it.
      delivery = if running_run?(sid, socket.assigns.status), do: "queue"

      ChannelTasks.reply_async(socket, fn ->
        case Sessions.send_text(sid, text, dir, files, delivery) do
          {:ok, _} -> {:ok, %{}}
          {:error, reason} -> error(reason)
        end
      end)
    end
  end

  def handle_in("interrupt", _params, socket) do
    sid = socket.assigns.session_id

    ChannelTasks.reply_async(socket, fn ->
      case Opencode.interrupt(sid) do
        {:ok, _} -> {:ok, %{}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("permission", %{"id" => id, "decision" => decision}, socket)
      when decision in @decisions do
    sid = socket.assigns.session_id

    ChannelTasks.reply_async(socket, fn ->
      case Opencode.reply_permission(sid, id, decision) do
        {:ok, _} -> {:ok, %{}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("options", _params, socket) do
    dir = Sessions.session_dir(socket.assigns.session, socket.assigns.project)

    ChannelTasks.reply_async(socket, fn ->
      default = Task.async(fn -> Opencode.default_model(dir) end)

      agents =
        case Opencode.agents(dir) do
          {:ok, list} -> for a <- list, a["mode"] != "subagent", !a["hidden"], do: a["id"]
          _ -> []
        end

      models =
        case Opencode.models() do
          {:ok, list} ->
            for m <- list,
                m["enabled"] != false,
                m["status"] != "deprecated",
                do: %{name: m["name"], value: "#{m["providerID"]}/#{m["id"]}"}

          _ ->
            []
        end

      # Named, so the chip says which model "no pick" means.
      default =
        case Task.yield(default, 15_000) || Task.shutdown(default) do
          {:ok, {:ok, %{"providerID" => p, "id" => id} = m}} ->
            %{name: m["name"] || id, value: "#{p}/#{id}"}

          _ ->
            nil
        end

      {:ok,
       %{agents: agents, models: models, default: default, slash: Sessions.slash_items(dir, 2)}}
    end)
  end

  def handle_in("find_files", %{"query" => query}, socket) when is_binary(query) do
    dir = Sessions.session_dir(socket.assigns.session, socket.assigns.project)

    ChannelTasks.reply_async(socket, fn ->
      # A bare `@` lists the top folder; find answers nothing outside git repos.
      found =
        if query == "",
          do: Opencode.list_dir(dir),
          else: Opencode.find_files(dir, String.slice(query, 0, 200))

      items =
        case found do
          {:ok, list} when is_list(list) ->
            for %{"path" => p} = f <- Enum.take(list, 50),
                p not in ["", "/", "."],
                do: %{path: p, type: f["type"]}

          _ ->
            []
        end

      {:ok, %{query: query, items: items}}
    end)
  end

  def handle_in("set_model", %{"model" => value}, socket) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [provider, id] ->
        sid = socket.assigns.session_id

        ChannelTasks.reply_async(
          socket,
          fn ->
            case Opencode.switch_model(sid, %{id: id, providerID: provider}) do
              {:ok, _} -> {:ok, %{}}
              {:error, reason} -> error(reason)
            end
          end,
          fn
            {:ok, _} = reply, socket ->
              {reply, update_session(socket, "model", %{"id" => id, "providerID" => provider})}

            reply, socket ->
              {reply, socket}
          end
        )

      _ ->
        {:reply, {:error, %{message: "Pick a model as provider/model."}}, socket}
    end
  end

  def handle_in("set_agent", %{"agent" => agent}, socket) when is_binary(agent) do
    sid = socket.assigns.session_id

    ChannelTasks.reply_async(
      socket,
      fn ->
        case Opencode.switch_agent(sid, agent) do
          {:ok, _} -> {:ok, %{}}
          {:error, reason} -> error(reason)
        end
      end,
      fn
        {:ok, _} = reply, socket -> {reply, update_session(socket, "agent", agent)}
        reply, socket -> {reply, socket}
      end
    )
  end

  def handle_in("rename", %{"title" => title}, socket) when is_binary(title) do
    title = String.trim(title)
    sid = socket.assigns.session_id

    if title == "" do
      {:reply, {:error, %{message: "A title can't be empty."}}, socket}
    else
      ChannelTasks.reply_async(socket, fn ->
        case Opencode.update_session(sid, %{title: title}) do
          {:ok, _} -> {:ok, %{}}
          {:error, reason} -> error(reason)
        end
      end)
    end
  end

  def handle_in("compact", _params, socket) do
    sid = socket.assigns.session_id

    ChannelTasks.reply_async(socket, fn ->
      case Opencode.compact(sid) do
        {:ok, _} -> {:ok, %{}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("run_again", _params, socket) do
    %{session_id: sid, project: project, user: user} = socket.assigns

    case Schedules.run_for_session(sid) do
      nil ->
        {:reply, {:error, %{message: "This session isn't a procedure run."}}, socket}

      run ->
        ChannelTasks.reply_async(socket, fn ->
          case Beamcode.Routines.run(project, user, run.inputs) do
            {:ok, new_run} -> {:ok, %{session_id: new_run.session_id}}
            {:error, reason} -> error(reason)
          end
        end)
    end
  end

  def handle_in("messages", _params, socket) do
    {messages, socket} = load_messages(assign(socket, sent: %{}))
    {:reply, {:ok, %{messages: messages}}, socket}
  end

  # A pasted image too big to travel with its message (see AppJSON.message/1).
  def handle_in("image", %{"message_id" => mid, "index" => index}, socket)
      when is_binary(mid) and is_integer(index) do
    sid = socket.assigns.session_id

    ChannelTasks.reply_async(socket, fn ->
      with {:ok, messages} <- Opencode.messages(sid),
           %{"files" => files} <- Enum.find(messages, &(&1["id"] == mid)),
           %{"mime" => "image/" <> _ = mime, "data" => data} when is_binary(data) <-
             Enum.at(List.wrap(files), index) do
        {:ok, %{mime: mime, data: data}}
      else
        {:error, reason} -> error(reason)
        _ -> {:error, %{message: "That image isn't there any more."}}
      end
    end)
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{message: "Unknown request."}}, socket}

  ## OpenCode events

  @impl true
  def handle_info({:oc_event, "session." <> kind = type, data}, socket)
      when kind in ["text.delta", "reasoning.delta"] do
    push(socket, "delta", %{
      message_id: data["assistantMessageID"],
      kind: if(type == "session.text.delta", do: "text", else: "reasoning"),
      delta: data["delta"] || ""
    })

    {:noreply, socket}
  end

  def handle_info({:oc_event, "session.renamed", %{"title" => title}}, socket) do
    session = Map.put(socket.assigns.session, "title", title)

    push(socket, "session", %{
      session: session_json(session, socket.assigns.project, socket.assigns.record)
    })

    {:noreply, assign(socket, session: session)}
  end

  def handle_info({:oc_event, "permission." <> kind, data}, socket) do
    if kind == "asked",
      do: push(socket, "speak", %{text: "Needs your OK: #{Inbox.permission_title(data)}."})

    {:noreply, push_status(socket, true)}
  end

  def handle_info({:oc_event, type, data}, socket) do
    socket =
      case type do
        "session.model.selected" -> update_session(socket, "model", data["model"])
        "session.agent.selected" -> update_session(socket, "agent", data["agent"])
        # Say the reply once the refetch has its final text.
        "session.execution.succeeded" -> assign(socket, speak_next: :reply)
        "session.execution.failed" -> assign(socket, speak_next: :failed)
        _ -> socket
      end
      |> push_status(false)

    if Events.messages_changed?(type),
      do: {:noreply, schedule_refetch(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:refetch, socket) do
    ids_before = Map.keys(socket.assigns.sent)
    {messages, socket} = load_messages(assign(socket, refetch_ref: nil), :changed)

    if messages.upsert != [] or length(messages.ids) != length(ids_before),
      do: push(socket, "messages", messages)

    diff = load_diff(socket.assigns.session_id)
    if diff != socket.assigns.diff, do: push(socket, "diff", %{files: diff})

    {:noreply, socket |> assign(diff: diff) |> speak()}
  end

  # The session's project made private or removed: close for those who can't see it now.
  def handle_info({:project_changed, %{id: id}}, %{assigns: %{project: %{id: id}}} = socket) do
    case ChannelTasks.still_visible(id, socket.assigns.user) do
      {:ok, project} ->
        {:noreply, assign(socket, project: project)}

      :gone ->
        push(socket, "gone", %{})
        {:stop, :normal, socket}
    end
  end

  def handle_info({:runs_changed, _}, socket) do
    if run = run(socket.assigns.session_id), do: push(socket, "run", %{run: run})
    {:noreply, socket}
  end

  def handle_info({ref, _} = msg, socket) when is_reference(ref),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info({:DOWN, _, :process, _, _} = msg, socket),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  # Messages oldest first, as the app shows them. With `:changed`, only those
  # that differ from what was last sent, plus the ids in order.
  defp load_messages(socket, mode \\ :all) do
    case Opencode.messages(socket.assigns.session_id) do
      {:ok, messages} ->
        messages =
          messages
          |> Enum.reject(&(&1["type"] == "idle" and &1["outcome"] == "succeeded"))
          |> Enum.map(&AppJSON.message/1)

        sent = socket.assigns.sent
        socket = assign(socket, sent: Map.new(messages, &{&1["id"], :erlang.phash2(&1)}))

        case mode do
          :all ->
            {messages, socket}

          :changed ->
            upsert = Enum.filter(messages, &(sent[&1["id"]] != :erlang.phash2(&1)))
            {%{upsert: upsert, ids: Enum.map(messages, & &1["id"])}, socket}
        end

      {:error, _reason} ->
        empty = if mode == :all, do: [], else: %{upsert: [], ids: Map.keys(socket.assigns.sent)}
        {empty, socket}
    end
  end

  defp load_diff(sid) do
    case Opencode.diff(sid) do
      {:ok, files} when is_list(files) ->
        for f <- files,
            do: Map.take(f, ["file", "additions", "deletions", "patch", "status"])

      _ ->
        []
    end
  end

  defp schedule_refetch(%{assigns: %{refetch_ref: nil}} = socket),
    do: assign(socket, refetch_ref: Process.send_after(self(), :refetch, @refetch_after))

  defp schedule_refetch(socket), do: socket

  # Pushes the status when it changed, or always with `force` (permissions moved).
  defp push_status(socket, force) do
    sid = socket.assigns.session_id
    status = Events.status(sid)

    if force or status != socket.assigns.status,
      do: push(socket, "status", %{status: status, perms: perms(sid)})

    assign(socket, status: status)
  end

  defp update_session(socket, key, value) do
    session = Map.put(socket.assigns.session, key, value)

    push(socket, "session", %{
      session: session_json(session, socket.assigns.project, socket.assigns.record)
    })

    assign(socket, session: session)
  end

  defp speak(%{assigns: %{speak_next: nil}} = socket), do: socket

  defp speak(%{assigns: %{speak_next: :failed}} = socket) do
    push(socket, "speak", %{text: "That failed. Details are on screen."})
    assign(socket, speak_next: nil)
  end

  defp speak(socket) do
    sid = socket.assigns.session_id

    text =
      case Opencode.messages(sid, 20) do
        {:ok, messages} -> Speech.reply_line(messages)
        _ -> ""
      end

    if text != "", do: push(socket, "speak", %{text: text})
    assign(socket, speak_next: nil)
  end

  defp perms(sid), do: Events.pending_for(sid) |> Enum.map(&AppJSON.perm/1)

  defp run(sid) do
    case Schedules.run_for_session(sid) do
      nil -> nil
      run -> AppJSON.run(run)
    end
  end

  defp running_run?(sid, status) do
    case Schedules.run_for_session(sid) do
      %{status: "running"} -> status in [:running, :waiting]
      _ -> false
    end
  end

  # With who started it, "only you" and the worktree folder for the header.
  defp session_json(session, project, record) do
    session
    |> Map.put("record", record)
    |> AppJSON.session(project)
    |> Map.put(:worktree, AppJSON.worktree(session, project))
  end

  defp error(reason), do: {:error, %{message: ChannelTasks.error_message(reason)}}
end
