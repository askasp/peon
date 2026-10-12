defmodule BeamcodeWeb.SessionChannel do
  @moduledoc """
  One session for the app ("session:<id>"), fed by the OpenCode events
  (`Beamcode.Opencode.Events`).

  Join replies `{session, project, messages, status, perms, forms, run, runs, diff}`
  (`runs`: the procedure runs in this chat and the runs they started, see
  `Beamcode.Schedules.chat_runs/1`).

  Requests:
    * `send` `{text, files?}` – files are `[{uri: "data:image/…;base64,…", name}]`
    * `interrupt`, `compact`, `rename` `{title}`, `run_again` → `{session_id}`
    * `permission` `{id, decision}` (once | always | reject)
    * `form_reply` `{id, answer}` – answers a question the agent asked; `form_cancel` `{id}` skips it
    * `options` → `{agents, models, slash}` for the pickers and `/` completion
    * `set_model` `{model: "provider/id", variant?}`, `set_agent` `{agent}`
    * `find_files` `{query}` → `{items}` for `@` completion ("" lists the top folder)
    * `messages` (all of them again)
    * `older` `{cursor}` → `{messages, older}`: the page of messages just older
      than the one on screen, so a chat opens with the newest page and loads
      earlier ones as you scroll up
    * `image` `{message_id, index}` → `{mime, data}`, a pasted image too big to come with its message
    * `run_continue` `{id, items?}`, `run_skip` `{id}`, `run_back` `{id, note}`, `run_stop` `{id}`
      → `{}`: answer a procedure run in this chat that waits for you, or stop it

  Pushes:
    * `delta` `{message_id, kind, delta}` – streamed text ("text" or "reasoning")
    * `messages` `{upsert, ids}` – stored messages that changed, and the order of all of them
    * `status` `{status, perms}` – idle | running | waiting, and pending permission requests
    * `session` `{session}` – renamed, or model/agent switched
    * `run` `{run}` – the routine run this session is, when it starts or finishes
    * `runs` `{runs}` – the procedure runs in this chat, when one moves on
    * `forms` `{forms}` – the questions the agent is waiting on, when they change
    * `diff` `{files}` – changed files (`file`, `additions`, `deletions`, `patch`, `hidden`), when they change
    * `speak` `{text}` – a short line to say: the reply when a turn ends, or a permission ask
  """
  use BeamcodeWeb, :channel

  alias Beamcode.{Inbox, Opencode, Procedures, Schedules, Sessions, Speech}
  alias Beamcode.Procedures.Runs
  alias Beamcode.Opencode.Events
  alias BeamcodeWeb.{AppJSON, ChannelTasks}

  @refetch_after 120
  # Messages per page: the chat opens with the newest page, and older ones load
  # as you scroll up (see the "older" request).
  @page 30
  # The diff is big on a big change; while the agent works it's read at most this often.
  @diff_after 1500
  @decisions ~w(once always reject)

  @impl true
  def join("session:" <> _id, _params, %{assigns: %{user: nil}}),
    do: {:error, %{reason: "unauthorized"}}

  def join("session:" <> id, _params, socket) do
    Beamcode.Instrument.span("channel session:join", %{session: id}, fn ->
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
              diff_ref: nil,
              diff_again: false,
              speak_next: nil,
              status: Events.status(id),
              diff: [],
              tasks: %{}
            )

          {messages, older, socket} = load_messages(socket)
          socket = assign(socket, diff: load_diff(id))

          {:ok,
           %{
             session: session_json(session, project, record),
             project: AppJSON.project(project),
             messages: messages,
             older: older,
             status: socket.assigns.status,
             perms: perms(id),
             forms: forms(id),
             run: run(id),
             runs: chat_runs(id),
             diff: socket.assigns.diff
           }, socket}

        :error ->
          {:error, %{reason: "not_found"}}
      end
    end)
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

      user = socket.assigns.user

      ChannelTasks.reply_async(socket, fn ->
        case procedure_message(project, sid, text, files) do
          {:run, name, values} ->
            case Runs.start(project, user, name, values, session_id: sid, trigger: "slash") do
              {:ok, _run} -> {:ok, %{}}
              {:error, reason} -> error(reason)
            end

          {:back, run} ->
            case Runs.back(run, text) do
              {:ok, _run} -> {:ok, %{}}
              {:error, reason} -> error(reason)
            end

          :send ->
            case Sessions.send_text(sid, text, dir, files, delivery) do
              {:ok, _} -> {:ok, %{}}
              {:error, reason} -> error(reason)
            end
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

  def handle_in("form_reply", %{"id" => id, "answer" => answer}, socket)
      when is_binary(id) and is_map(answer) do
    sid = socket.assigns.session_id

    ChannelTasks.reply_async(socket, fn ->
      case Opencode.reply_form(sid, id, answer) do
        {:ok, _} -> {:ok, %{}}
        {:error, reason} -> error(reason)
      end
    end)
  end

  def handle_in("form_cancel", %{"id" => id}, socket) when is_binary(id) do
    sid = socket.assigns.session_id

    ChannelTasks.reply_async(socket, fn ->
      case Opencode.cancel_form(sid, id) do
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
                do: model_json(m)

          _ ->
            []
        end

      # Named, so the chip says which model "no pick" means.
      default =
        case Task.yield(default, 15_000) || Task.shutdown(default) do
          {:ok, {:ok, %{"providerID" => _, "id" => id} = m}} ->
            %{model_json(m) | name: m["name"] || id}

          _ ->
            nil
        end

      # Procedures first; an Operations Folder's `/` lists only those.
      procedures = Procedures.slash_items(socket.assigns.project)
      names = MapSet.new(procedures, & &1.name)

      slash =
        if socket.assigns.project.kind == "routine",
          do: procedures,
          else: procedures ++ Enum.reject(Sessions.slash_items(dir, 2), &MapSet.member?(names, &1.name))

      {:ok, %{agents: agents, models: models, default: default, slash: slash}}
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

  def handle_in("set_model", %{"model" => value} = params, socket) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [provider, id] ->
        sid = socket.assigns.session_id
        # How hard the model thinks ("low", "high", …); none is the model's default.
        model =
          case params["variant"] do
            v when is_binary(v) and v != "" ->
              %{"id" => id, "providerID" => provider, "variant" => v}

            _ ->
              %{"id" => id, "providerID" => provider}
          end

        ChannelTasks.reply_async(
          socket,
          fn ->
            case Opencode.switch_model(sid, model) do
              {:ok, _} -> {:ok, %{}}
              {:error, reason} -> error(reason)
            end
          end,
          fn
            {:ok, _} = reply, socket -> {reply, update_session(socket, "model", model)}
            reply, socket -> {reply, socket}
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

  def handle_in("run_" <> action, %{"id" => id} = params, socket)
      when action in ["continue", "skip", "back", "stop"] do
    %{session_id: sid, user: user, project: project} = socket.assigns

    case Enum.find(Schedules.chat_runs(sid), &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:reply, {:error, %{message: "No such run in this chat."}}, socket}

      run ->
        if Beamcode.ProjectTools.can_edit?(project, user) do
          ChannelTasks.reply_async(socket, fn ->
            result =
              case action do
                "continue" ->
                  items = if is_list(params["items"]), do: Enum.filter(params["items"], &is_map/1)
                  Runs.continue(run, items: items)

                "skip" ->
                  Runs.skip(run)

                "back" ->
                  Runs.back(run, to_string(params["note"] || ""))

                "stop" ->
                  Runs.stop(run)
              end

            case result do
              {:ok, _} -> {:ok, %{}}
              {:error, reason} -> error(reason)
            end
          end)
        else
          {:reply, {:error, %{message: "You can't change this Folder."}}, socket}
        end
    end
  end

  def handle_in("run_again", _params, socket) do
    %{session_id: sid, project: project, user: user} = socket.assigns

    case Schedules.run_for_session(sid) do
      nil ->
        {:reply, {:error, %{message: "This session isn't a procedure run."}}, socket}

      run ->
        ChannelTasks.reply_async(socket, fn ->
          case Runs.start(project, user, run.procedure, run.inputs) do
            {:ok, run} -> {:ok, %{session_id: run.session_id}}
            {:error, reason} -> error(reason)
          end
        end)
    end
  end

  def handle_in("messages", _params, socket) do
    {messages, older, socket} = load_messages(assign(socket, sent: %{}))
    {:reply, {:ok, %{messages: messages, older: older}}, socket}
  end

  # The page just older than `cursor`: the chat loads earlier messages as you
  # scroll up, instead of fetching the whole history on open.
  def handle_in("older", %{"cursor" => cursor}, socket) when is_binary(cursor) do
    sid = socket.assigns.session_id

    ChannelTasks.reply_async(socket, fn ->
      case Opencode.messages_page(sid, limit: @page, cursor: cursor) do
        {:ok, %{messages: messages, next: next}} ->
          messages =
            messages
            |> Enum.reject(&(&1["type"] == "idle" and &1["outcome"] == "succeeded"))
            |> Enum.map(&AppJSON.message/1)

          {:ok, %{messages: messages, older: next}}

        {:error, reason} ->
          error(reason)
      end
    end)
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

  def handle_info({:oc_event, "form." <> kind, data}, socket) do
    if kind == "created",
      do: push(socket, "speak", %{text: "A question for you: #{get_in(data, ["form", "title"])}"})

    # Fetched off the channel process, so a slow OpenCode doesn't hold it up.
    channel = self()
    sid = socket.assigns.session_id
    Task.start(fn -> send(channel, {:forms, forms(sid)}) end)
    # A question waiting makes the session "waiting".
    {:noreply, push_status(socket, false)}
  end

  def handle_info({:forms, forms}, socket) do
    push(socket, "forms", %{forms: forms})
    {:noreply, socket}
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

    {:noreply, socket |> schedule_diff() |> speak()}
  end

  # Read off the channel process, so pushes and replies don't wait for it.
  def handle_info(:load_diff, socket) do
    channel = self()
    sid = socket.assigns.session_id

    Task.start(fn ->
      diff =
        try do
          load_diff(sid)
        rescue
          _ -> :error
        end

      send(channel, {:diff, diff})
    end)

    {:noreply, assign(socket, diff_ref: :loading, diff_again: false)}
  end

  def handle_info({:diff, :error}, socket),
    do: {:noreply, assign(socket, diff_ref: nil)}

  def handle_info({:diff, diff}, socket) do
    if diff != socket.assigns.diff, do: push(socket, "diff", %{files: diff})
    socket = assign(socket, diff: diff, diff_ref: nil)
    {:noreply, if(socket.assigns.diff_again, do: schedule_diff(socket), else: socket)}
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

  def handle_info({:runs_changed, pid}, socket) do
    sid = socket.assigns.session_id
    if run = run(sid), do: push(socket, "run", %{run: run})

    if pid in [nil, socket.assigns.project.id] do
      runs = chat_runs(sid)
      if runs != [] or socket.assigns[:had_runs], do: push(socket, "runs", %{runs: runs})
      {:noreply, assign(socket, had_runs: runs != [])}
    else
      {:noreply, socket}
    end
  end

  def handle_info({ref, _} = msg, socket) when is_reference(ref),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info({:DOWN, _, :process, _, _} = msg, socket),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  # The newest page of messages, oldest first, as the app shows them. With
  # `:changed`, only the ones that differ from what was last sent, plus the ids
  # in order. `:all` also returns the cursor for the page just older (or nil).
  defp load_messages(socket, mode \\ :all) do
    Beamcode.Instrument.span("session:load_messages", %{mode: mode}, fn ->
      case Opencode.messages_page(socket.assigns.session_id, limit: @page) do
        {:ok, %{messages: messages, next: next}} ->
          messages =
            messages
            |> Enum.reject(&(&1["type"] == "idle" and &1["outcome"] == "succeeded"))
            |> Enum.map(&AppJSON.message/1)

          sent = socket.assigns.sent
          socket = assign(socket, sent: Map.new(messages, &{&1["id"], :erlang.phash2(&1)}))

          case mode do
            :all ->
              {messages, next, socket}

            :changed ->
              upsert = Enum.filter(messages, &(sent[&1["id"]] != :erlang.phash2(&1)))
              {%{upsert: upsert, ids: Enum.map(messages, & &1["id"])}, socket}
          end

        {:error, _reason} ->
          if mode == :all,
            do: {[], nil, socket},
            else: {%{upsert: [], ids: Map.keys(socket.assigns.sent)}, socket}
      end
    end)
  end

  # Each patch cut to its changes (OpenCode sends whole files), with `hidden`
  # lines left out past the cap.
  defp load_diff(sid) do
    Beamcode.Instrument.span("session:load_diff", %{session: sid}, fn ->
      case Opencode.diff(sid) do
        {:ok, files} when is_list(files) ->
          for f <- files do
            f = Map.take(f, ["file", "additions", "deletions", "patch", "status"])

            case f["patch"] do
              patch when is_binary(patch) ->
                {patch, hidden} = Beamcode.Patch.trim(patch)
                Map.merge(f, %{"patch" => patch, "hidden" => hidden})

              _ ->
                f
            end
          end

        _ ->
          []
      end
    end)
  end

  defp schedule_refetch(%{assigns: %{refetch_ref: nil}} = socket),
    do: assign(socket, refetch_ref: Process.send_after(self(), :refetch, @refetch_after))

  defp schedule_refetch(socket), do: socket

  # While a read is out, one more follows it, so the last change is never missed.
  defp schedule_diff(%{assigns: %{diff_ref: nil}} = socket),
    do: assign(socket, diff_ref: Process.send_after(self(), :load_diff, @diff_after))

  defp schedule_diff(%{assigns: %{diff_ref: :loading}} = socket),
    do: assign(socket, diff_again: true)

  defp schedule_diff(socket), do: socket

  # Pushes the status when it changed, or always with `force` (permissions moved).
  defp push_status(socket, force) do
    sid = socket.assigns.session_id
    status = Events.status(sid)

    if force or status != socket.assigns.status,
      do: push(socket, "status", %{status: status, perms: perms(sid)})

    assign(socket, status: status)
  end

  # A model for the pickers, with how hard it can think (OpenCode's variants).
  defp model_json(m) do
    %{
      name: m["name"],
      value: "#{m["providerID"]}/#{m["id"]}",
      variants: for(%{"id" => v} <- m["variants"] || [], do: v),
      variant: get_in(m, ["options", "variant"]),
      # Tokens the model can hold, for the context meter.
      context: get_in(m, ["limit", "context"])
    }
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

  # The questions still waiting for an answer.
  defp forms(sid) do
    case Opencode.session_forms(sid) do
      {:ok, list} when is_list(list) ->
        for f <- list,
            get_in(f, ["state", "status"]) in [nil, "pending"],
            do: Map.take(f, ["id", "title", "fields", "metadata"])

      _ ->
        []
    end
  end

  defp chat_runs(sid), do: sid |> Schedules.chat_runs() |> Enum.map(&AppJSON.run/1)

  defp run(sid) do
    case Schedules.run_for_session(sid) do
      nil -> nil
      run -> AppJSON.run(run)
    end
  end

  # What a typed message does: `/name …` starts a procedure from a file (a
  # legacy skill one is sent as it is), and text at a run that waits for you
  # after a step sends it back with that note.
  defp procedure_message(project, sid, text, files) do
    with [_, name, rest] <- Regex.run(~r{^/([\w.-]+)\s*(.*)$}s, String.trim(text)),
         [] <- files,
         %{source: source} = p when source != "legacy" <- Procedures.find(project, name) do
      {:run, p, typed_values(p, rest)}
    else
      _ ->
        case Runs.waiting_in(sid) do
          %{waiting: %{"kind" => kind}} = run when kind in ["after", "changes"] and files == [] ->
            {:back, run}

          _ ->
            :send
        end
    end
  end

  # "charge: ch_1, amount: 299" sets those inputs; other text goes to the one
  # input there is, else rides along as `request`.
  defp typed_values(_p, ""), do: %{}

  defp typed_values(p, rest) do
    pairs =
      for part <- String.split(rest, ~r/,\s*/),
          [_, k, v] <- [Regex.run(~r/^([\w-]+):\s*(.+)$/s, String.trim(part))],
          into: %{},
          do: {k, String.trim(v)}

    names = Enum.map(p.inputs, & &1.name)

    cond do
      pairs != %{} and Enum.all?(Map.keys(pairs), &(&1 in names)) -> pairs
      length(names) == 1 -> %{hd(names) => rest}
      true -> %{"request" => rest}
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
