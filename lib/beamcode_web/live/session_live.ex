defmodule BeamcodeWeb.SessionLive do
  @moduledoc """
  One OpenCode session: messages (streamed live), inline permission requests,
  the composer, and the changed files with their diff.
  """
  use BeamcodeWeb, :live_view
  alias Beamcode.{Opencode, Projects, Sessions}
  alias Beamcode.Opencode.Events
  alias BeamcodeWeb.{Markdown, Shell}

  @refetch_on ~w(session.inbox.delivered session.tool.called session.tool.success session.tool.failed
                 session.tool.error session.text.ended session.reasoning.ended session.step.ended
                 session.step.failed session.execution.succeeded session.execution.failed
                 session.execution.interrupted session.agent.selected session.model.selected
                 session.compaction.completed session.shell.ended session.skill.completed)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, session} <- Opencode.get_session(id),
         project when project != nil <-
           Projects.project_for_session(session, Projects.list_visible(user)),
         record = Projects.session_record(id),
         true <- Projects.session_visible?(record, user) do
      if connected?(socket), do: Events.subscribe_session(id)

      socket =
        socket
        |> Shell.set_current(project, id)
        |> assign(
          session: session,
          project: project,
          record: record,
          page_title: session["title"] || "Session"
        )
        |> assign(
          msgs: %{},
          raw: [],
          inserted: %{},
          run: Beamcode.Schedules.run_for_session(id),
          show_transcript: false,
          result: "",
          steps: [],
          streaming: %{},
          refetch_ref: nil,
          diff: [],
          diff_file: nil,
          sending: false
        )
        |> assign(
          agents: [],
          models: [],
          slash: [],
          status: Events.status(id),
          perms: Events.pending_for(id)
        )
        |> stream_configure(:messages, dom_id: &("msg-" <> &1["id"]))
        |> stream(:messages, [])
        |> load_messages()
        |> load_diff()

      socket =
        if connected?(socket) do
          dir = directory(session, project)

          start_async(socket, :options, fn ->
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
                      do: {m["name"], "#{m["providerID"]}/#{m["id"]}"}

                _ ->
                  []
              end

            {agents, models, Sessions.slash_items(dir)}
          end)
        else
          socket
        end

      {:ok, socket}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found, or not yours to see.")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp directory(session, project),
    do: get_in(session, ["location", "directory"]) || project.directory

  defp load_messages(socket) do
    case Opencode.messages(socket.assigns.session["id"]) do
      {:ok, messages} ->
        messages = Enum.reject(messages, &(&1["type"] == "idle" and &1["outcome"] == "succeeded"))
        msgs = Map.new(messages, &{&1["id"], &1})

        # Drop streamed text once the stored message has caught up.
        streaming =
          Map.reject(socket.assigns.streaming, fn {id, s} ->
            case msgs[id] do
              nil -> false
              m -> m["time"]["completed"] != nil or stored_text_length(m) >= String.length(s.text)
            end
          end)

        socket
        |> assign(msgs: msgs, raw: messages, streaming: streaming)
        |> restream()

      {:error, reason} ->
        put_flash(socket, :error, "Could not load messages: #{Shell.format_error(reason)}")
    end
  end

  # Builds the rendered items (stored messages + streamed text, folded for runs)
  # and only re-sends the ones that changed.
  defp restream(socket) do
    %{raw: raw, streaming: streaming} = socket.assigns
    known = MapSet.new(raw, & &1["id"])

    pending =
      for {id, _} <- streaming,
          not MapSet.member?(known, id),
          do: %{"id" => id, "type" => "assistant", "content" => [], "time" => %{}}

    items = Enum.map(raw ++ pending, &merge_streaming(&1, streaming))

    {items, result, steps} =
      if socket.assigns.run, do: fold_run(items, socket), else: {items, "", []}

    old = socket.assigns.inserted
    changed = Enum.filter(items, &(old[&1["id"]] != &1))

    socket
    |> assign(inserted: Map.new(items, &{&1["id"], &1}), result: result, steps: steps)
    |> stream(:messages, changed)
  end

  # A run's first turn (its prompt and the work up to the result) is folded into
  # one "Run transcript" card; the result goes to the left panel.
  defp fold_run(items, socket) do
    user_idx =
      items
      |> Enum.with_index()
      |> Enum.filter(fn {m, _} -> m["type"] == "user" end)
      |> Enum.map(&elem(&1, 1))

    first = List.first(user_idx)
    second = Enum.at(user_idx, 1) || length(items)
    first_turn = if first, do: Enum.slice(items, first, second - first), else: []

    result =
      first_turn
      |> Enum.filter(&(&1["type"] == "assistant"))
      |> Enum.flat_map(fn m ->
        for %{"type" => "text", "text" => t} <- m["content"] || [], t != "", do: t
      end)
      |> List.last()
      |> Kernel.||("")

    tool_parts =
      first_turn
      |> Enum.flat_map(&(&1["content"] || []))
      |> Enum.filter(&(&1["type"] == "tool"))

    tools = length(tool_parts)

    show = socket.assigns.show_transcript

    items =
      items
      |> Enum.with_index()
      |> Enum.map(fn {m, i} ->
        cond do
          first == nil or i < first or i >= second ->
            m

          i == first ->
            Map.merge(m, %{"_view" => if(show, do: "card_open", else: "card"), "_tools" => tools})

          show ->
            m

          true ->
            Map.put(m, "_view", "hidden")
        end
      end)

    {items, result, run_steps(tool_parts, result)}
  end

  # Progress while a run works: its tool calls, grouped ("front · get_conversation ×6"),
  # then writing the result. OpenCode v2 has no todo list to read steps from.
  defp run_steps(tool_parts, result) do
    calls =
      tool_parts
      |> Enum.map(&{short_tool(&1), get_in(&1, ["state", "status"])})
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(fn [{label, _} | _] = group ->
        statuses = Enum.map(group, &elem(&1, 1))

        state =
          cond do
            Enum.any?(statuses, &(&1 in ["running", "streaming", nil])) -> :current
            Enum.all?(statuses, &(&1 == "error")) -> :failed
            true -> :done
          end

        %{label: label, count: length(group), state: state}
      end)

    busy = Enum.any?(calls, &(&1.state == :current))

    write = %{
      label: "Write the result",
      count: 1,
      state: if(result == "", do: :pending, else: :current)
    }

    write = if busy, do: %{write | state: :pending}, else: write
    calls ++ [write]
  end

  defp stored_text_length(m) do
    (m["content"] || [])
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(&String.length(&1["text"] || ""))
    |> Enum.sum()
  end

  defp merge_streaming(msg, streaming) do
    case streaming[msg["id"]] do
      nil ->
        msg

      s ->
        parts = msg["content"] || []

        parts =
          parts ++
            if(s.reasoning != "" and not Enum.any?(parts, &(&1["type"] == "reasoning")),
              do: [%{"type" => "reasoning", "text" => s.reasoning}],
              else: []
            ) ++
            if(s.text != "" and stored_text_length(msg) < String.length(s.text),
              do: [%{"type" => "text", "text" => s.text, "streaming" => true}],
              else: []
            )

        Map.put(msg, "content", parts)
    end
  end

  defp load_diff(socket) do
    case Opencode.diff(socket.assigns.session["id"]) do
      {:ok, files} when is_list(files) -> assign(socket, :diff, files)
      _ -> socket
    end
  end

  defp schedule_refetch(socket) do
    if socket.assigns.refetch_ref,
      do: socket,
      else: assign(socket, :refetch_ref, Process.send_after(self(), :refetch, 120))
  end

  ## Events from OpenCode

  @impl true
  def handle_info({:oc_event, type, data}, socket)
      when type in ["session.text.delta", "session.reasoning.delta"] do
    id = data["assistantMessageID"]
    key = if type == "session.text.delta", do: :text, else: :reasoning
    entry = Map.get(socket.assigns.streaming, id, %{text: "", reasoning: ""})
    entry = Map.update!(entry, key, &(&1 <> (data["delta"] || "")))
    streaming = Map.put(socket.assigns.streaming, id, entry)

    {:noreply, socket |> assign(:streaming, streaming) |> restream()}
  end

  def handle_info({:oc_event, "session.renamed", %{"title" => title}}, socket) do
    {:noreply,
     socket
     |> assign(session: Map.put(socket.assigns.session, "title", title), page_title: title)
     |> Shell.set_current(socket.assigns.project, socket.assigns.session["id"])}
  end

  def handle_info({:oc_event, "permission." <> _, _data}, socket) do
    id = socket.assigns.session["id"]
    {:noreply, assign(socket, perms: Events.pending_for(id), status: Events.status(id))}
  end

  def handle_info({:oc_event, type, data}, socket) do
    id = socket.assigns.session["id"]
    socket = assign(socket, status: Events.status(id), perms: Events.pending_for(id))

    socket =
      case type do
        "session.model.selected" ->
          assign(socket, session: Map.put(socket.assigns.session, "model", data["model"]))

        "session.agent.selected" ->
          assign(socket, session: Map.put(socket.assigns.session, "agent", data["agent"]))

        _ ->
          socket
      end

    if type in @refetch_on or String.starts_with?(type, "session.execution."),
      do: {:noreply, schedule_refetch(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:refetch, socket) do
    socket = socket |> assign(refetch_ref: nil) |> load_messages() |> load_diff()

    socket =
      if socket.assigns.run,
        do: assign(socket, run: Beamcode.Schedules.run_for_session(socket.assigns.session["id"])),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:runs_changed, _}, socket) do
    if socket.assigns.run,
      do:
        {:noreply,
         assign(socket, run: Beamcode.Schedules.run_for_session(socket.assigns.session["id"]))},
      else: {:noreply, socket}
  end

  def handle_info({:oc_activity, _, _}, socket) do
    id = socket.assigns.session["id"]
    {:noreply, assign(socket, status: Events.status(id), perms: Events.pending_for(id))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:options, {:ok, {agents, models, slash}}, socket) do
    {:noreply, assign(socket, agents: agents, models: models, slash: slash)}
  end

  def handle_async(:options, _, socket), do: {:noreply, socket}

  def handle_async(:slash, {:ok, slash}, socket), do: {:noreply, assign(socket, slash: slash)}
  def handle_async(:slash, _, socket), do: {:noreply, socket}

  def handle_async(:send, {:ok, {:ok, _}}, socket), do: {:noreply, assign(socket, sending: false)}

  def handle_async(:send, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(sending: false)
     |> put_flash(:error, "Not sent: #{Shell.format_error(reason)}")}
  end

  def handle_async(:send, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(sending: false) |> put_flash(:error, "Not sent: #{inspect(reason)}")}
  end

  ## UI events

  @impl true
  def handle_event("send", %{"text" => text} = params, socket) do
    files =
      for %{"uri" => "data:image/" <> _ = uri} = f <- List.wrap(params["files"]),
          do: %{uri: uri, name: f["name"] || "image.png"}

    if String.trim(text) == "" and files == [] do
      {:noreply, socket}
    else
      sid = socket.assigns.session["id"]
      dir = directory(socket.assigns.session, socket.assigns.project)
      # While a run works, follow-ups wait for it instead of steering it.
      delivery = if running_run?(socket.assigns.run, socket.assigns.status), do: "queue"

      {:noreply,
       socket
       |> assign(sending: true)
       |> start_async(:send, fn -> Sessions.send_text(sid, text, dir, files, delivery) end)}
    end
  end

  # The composer asks again when `/` is typed and the list is still empty.
  def handle_event("load_slash", _params, %{assigns: %{slash: []}} = socket) do
    dir = directory(socket.assigns.session, socket.assigns.project)
    {:noreply, start_async(socket, :slash, fn -> Sessions.slash_items(dir, 2) end)}
  end

  def handle_event("load_slash", _params, socket), do: {:noreply, socket}

  # `@` completion in the composer.
  def handle_event("find_files", %{"query" => query}, socket) when is_binary(query) do
    dir = directory(socket.assigns.session, socket.assigns.project)

    # A bare `@` lists the top folder; find answers nothing outside git repos.
    found =
      if query == "",
        do: Opencode.list_dir(dir),
        else: Opencode.find_files(dir, String.slice(query, 0, 200))

    items =
      case found do
        {:ok, list} when is_list(list) ->
          for %{"path" => p} = f <- list, do: %{path: p, type: f["type"]}

        _ ->
          []
      end

    {:reply, %{query: query, items: items}, socket}
  end

  def handle_event("permission", %{"id" => perm_id, "decision" => decision}, socket) do
    case Opencode.reply_permission(socket.assigns.session["id"], perm_id, decision) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, e} ->
        {:noreply, put_flash(socket, :error, "Could not reply: #{Shell.format_error(e)}")}
    end
  end

  def handle_event("interrupt", _params, socket), do: {:noreply, interrupt(socket)}

  def handle_event("toggle_transcript", _params, socket) do
    {:noreply, socket |> assign(show_transcript: !socket.assigns.show_transcript) |> restream()}
  end

  def handle_event("run_again", _params, socket) do
    %{project: project, run: run, current_scope: %{user: user}} = socket.assigns

    case Beamcode.Routines.run(project, user, run.inputs) do
      {:ok, new_run} ->
        {:noreply, push_navigate(socket, to: ~p"/s/#{new_run.session_id}")}

      {:error, e} ->
        {:noreply, put_flash(socket, :error, "Run failed to start: #{Shell.format_error(e)}")}
    end
  end

  def handle_event("set_model", %{"model" => value}, socket) do
    case String.split(value, "/", parts: 2) do
      [provider, id] ->
        case Opencode.switch_model(socket.assigns.session["id"], %{id: id, providerID: provider}) do
          {:ok, _} ->
            {:noreply,
             assign(socket,
               session:
                 Map.put(socket.assigns.session, "model", %{"id" => id, "providerID" => provider})
             )}

          {:error, e} ->
            {:noreply, put_flash(socket, :error, Shell.format_error(e))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_agent", %{"agent" => agent}, socket),
    do: {:noreply, set_agent(socket, agent)}

  def handle_event("cycle_agent", %{"dir" => dir}, socket),
    do: {:noreply, cycle_agent(socket, dir)}

  def handle_event("show_file", %{"file" => file}, socket) do
    {:noreply,
     assign(socket, diff_file: if(socket.assigns.diff_file == file, do: nil, else: file))}
  end

  def handle_event("rename", %{"title" => title}, socket) do
    title = String.trim(title)

    if title != "" do
      _ = Opencode.update_session(socket.assigns.session["id"], %{title: title})
    end

    {:noreply, socket}
  end

  # Shortcuts forwarded by BeamcodeWeb.Shell.
  def handle_keybind("session_interrupt", socket), do: interrupt(socket)

  def handle_keybind("session_compact", socket) do
    case Opencode.compact(socket.assigns.session["id"]) do
      {:ok, _} -> put_flash(socket, :info, "Compacting…")
      {:error, e} -> put_flash(socket, :error, Shell.format_error(e))
    end
  end

  def handle_keybind("agent_cycle", socket), do: cycle_agent(socket, "next")
  def handle_keybind("agent_cycle_reverse", socket), do: cycle_agent(socket, "prev")
  def handle_keybind(_action, socket), do: socket

  defp interrupt(socket) do
    if socket.assigns.status in [:running, :waiting] do
      case Opencode.interrupt(socket.assigns.session["id"]) do
        {:ok, _} -> socket
        {:error, e} -> put_flash(socket, :error, Shell.format_error(e))
      end
    else
      socket
    end
  end

  defp current_agent(socket),
    do: socket.assigns.session["agent"] || List.first(socket.assigns.agents) || "build"

  defp cycle_agent(socket, dir) do
    agents = socket.assigns.agents

    if agents == [] do
      socket
    else
      i = Enum.find_index(agents, &(&1 == current_agent(socket))) || 0
      step = if dir == "prev", do: -1, else: 1
      set_agent(socket, Enum.at(agents, rem(i + step + length(agents), length(agents))))
    end
  end

  defp set_agent(socket, agent) do
    case Opencode.switch_agent(socket.assigns.session["id"], agent) do
      {:ok, _} -> assign(socket, session: Map.put(socket.assigns.session, "agent", agent))
      {:error, e} -> put_flash(socket, :error, Shell.format_error(e))
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={@project.id}>
      <div
        :if={@run}
        id="run-header"
        class="flex-none h-14 flex items-center gap-3 px-6 border-b border-line"
      >
        <.link navigate={~p"/p/#{@project.id}"} class="text-[13.5px] text-muted hover:text-fg">
          {@project.name}
        </.link>
        <span class="text-faint">/</span>
        <span class="text-[15px] font-semibold whitespace-nowrap">{run_title(@run)}</span>
        <.run_badge run={@run} status={@status} />
        <span class="text-[12.5px] text-muted truncate">{run_meta(@run, @current_scope.user)} ·</span>
        <span
          :if={running_run?(@run, @status)}
          id="run-elapsed"
          phx-hook=".Elapsed"
          phx-update="ignore"
          data-start={DateTime.to_unix(@run.inserted_at, :millisecond)}
          class="-ml-2 text-[12.5px] text-muted font-mono tabular-nums"
        >0:00</span>
        <span :if={!running_run?(@run, @status)} class="-ml-2 text-[12.5px] text-muted">
          {BeamcodeWeb.ProjectLive.run_duration(@run)}
        </span>
        <div class="ml-auto flex items-center gap-2">
          <button
            :if={running_run?(@run, @status)}
            id="interrupt-button"
            class="btn"
            phx-click="interrupt"
          >
            Stop
          </button>
          <button
            :if={!running_run?(@run, @status)}
            class="btn"
            id="run-again"
            phx-click="run_again"
            phx-disable-with="Starting…"
          >
            Run again
          </button>
        </div>
      </div>

      <div :if={!@run} class="flex-none h-14 flex items-center gap-3 px-6 border-b border-line">
        <div class="flex-1 min-w-0 flex flex-col">
          <form id="title-form" phx-submit="rename" class="min-w-0">
            <input
              id="session-title"
              name="title"
              value={@session["title"] || "New session"}
              class="w-full bg-transparent outline-none text-[14.5px] font-semibold truncate rounded px-1 -mx-1 hover:bg-panel focus:bg-panel"
            />
          </form>
          <span class="text-[12px] text-muted truncate">
            <.link navigate={~p"/p/#{@project.id}"} class="hover:text-fg">{@project.name}</.link>
            {location_label(@session, @project)}{if @record && @record.user,
              do: " · " <> @record.user.username}{if @record && @record.scope == "private",
              do: " · only you"}
          </span>
        </div>
        <div class="ml-auto flex items-center gap-2">
          <Layouts.status_badge status={@status} />
          <button
            :if={@status in [:running, :waiting]}
            id="interrupt-button"
            class="btn btn-sm"
            phx-click="interrupt"
            title={"Interrupt (" <> Beamcode.Keybinds.label(@keybinds["session_interrupt"], @kb_prefs["prefix"]) <> ")"}
          >
            Stop
          </button>
        </div>
      </div>

      <div class="flex-1 min-h-0 flex">
        <section
          :if={@run}
          id="run-result-panel"
          class="flex-1 min-w-0 flex flex-col border-r border-line"
        >
          <div class="flex-none flex items-center gap-1.5 px-6 py-3 border-b border-line">
            <span class="h-7 flex items-center px-2.5 rounded-[7px] bg-raised text-[13px]">Result</span>
            <button
              :if={running_run?(@run, @status)}
              type="button"
              id="full-transcript"
              phx-click="toggle_transcript"
              class="ml-auto text-[12.5px] text-muted hover:text-fg transition"
            >
              {if @show_transcript, do: "Hide transcript", else: "Full transcript"}
            </button>
            <button
              :if={@result != "" and !running_run?(@run, @status)}
              type="button"
              id="copy-result"
              phx-click={JS.dispatch("chatos:copy", to: "#run-result")}
              class="ml-auto text-[12.5px] text-muted hover:text-fg transition"
            >
              Copy
            </button>
          </div>
          <div class="flex-1 min-h-0 overflow-y-auto px-8 py-6">
            <%= if running_run?(@run, @status) do %>
              <div class="max-w-[720px] flex flex-col gap-[22px]">
                <div id="run-steps" class="flex flex-col">
                  <div :for={step <- @steps} class="flex items-start gap-3 py-[9px]">
                    <.step_dot state={step.state} />
                    <span class={[
                      "text-[14px]",
                      if(step.state == :pending, do: "text-muted", else: "text-fg")
                    ]}>
                      {step.label}<span :if={step.count > 1} class="text-muted"> ×{step.count}</span>
                    </span>
                  </div>
                  <div
                    :if={@status == :waiting}
                    class="flex items-center gap-3 py-[9px] text-[13.5px] text-wait"
                  >
                    <span class="w-[18px] h-[18px] flex-none rounded-full shadow-[inset_0_0_0_1.5px_var(--color-wait)]"></span>
                    Waiting for your permission on the right
                  </div>
                </div>
                <div :if={@result != ""} class="flex flex-col gap-2.5 pt-[18px] border-t border-line">
                  <span class="text-[12.5px] text-muted">Result so far</span>
                  <div id="run-result" class="md result streaming">{Markdown.to_html(@result)}</div>
                </div>
              </div>
            <% else %>
              <div :if={@result != ""} id="run-result" class="md result max-w-[720px]">
                {Markdown.to_html(@result)}
              </div>
              <div :if={@result == ""} class="text-[13px] text-faint">
                {if @run.status == "failed",
                  do: "The run failed. " <> (@run.error || ""),
                  else: "No result text."}
              </div>
            <% end %>
          </div>
        </section>
        <div class={["min-w-0 flex flex-col", if(@run, do: "w-[460px] flex-none", else: "flex-1")]}>
          <div
            :if={@run}
            class="flex-none h-[53px] flex items-center px-5 border-b border-line text-[13px] text-muted"
          >
            Follow up on this run
          </div>
          <div
            :if={quiet_follow_up?(assigns)}
            id="follow-up-quiet"
            class="flex-1 min-h-0 flex items-center justify-center px-12 text-center text-[13.5px] leading-relaxed text-muted text-pretty"
          >
            You can ask about the result when the run is done. Anything you send now is queued until then.
          </div>
          <div
            id="messages-scroll"
            phx-hook=".ScrollBottom"
            class={["flex-1 min-h-0 overflow-y-auto", quiet_follow_up?(assigns) && "hidden"]}
          >
            <div class={[
              "flex flex-col gap-3.5",
              if(@run, do: "px-5 py-4", else: "max-w-[820px] mx-auto px-8 py-6")
            ]}>
              <div id="messages" phx-update="stream" class="flex flex-col gap-3.5">
                <div
                  id="messages-empty"
                  class="hidden only:block text-center text-[13.5px] text-faint py-16"
                >
                  Send a message to start.
                </div>
                <div :for={{dom_id, msg} <- @streams.messages} id={dom_id}>
                  <.message msg={msg} />
                </div>
              </div>

              <div
                :for={perm <- @perms}
                id={"perm-#{perm["id"]}"}
                class="flex flex-col gap-2.5 px-4 py-3.5 rounded-xl bg-waitbg shadow-[inset_0_0_0_1px_var(--color-waitline)]"
              >
                <div class="flex items-center gap-2">
                  <span class="text-[13px] font-semibold text-wait">Permission</span>
                  <span class="text-[13px]">{Beamcode.Inbox.permission_title(perm)}</span>
                </div>
                <pre
                  :if={perm["resources"] not in [nil, [], ["*"]]}
                  class="px-4 py-3 rounded-[10px] bg-code shadow-[inset_0_0_0_1px_var(--color-line)] font-mono text-[12.5px] leading-relaxed text-soft whitespace-pre-wrap break-all"
                  phx-no-format
                >{Enum.join(perm["resources"], "\n")}</pre>
                <div class="flex gap-2">
                  <button
                    class="btn btn-primary"
                    phx-click="permission"
                    phx-value-id={perm["id"]}
                    phx-value-decision="once"
                    id={"perm-once-#{perm["id"]}"}
                  >Allow once</button>
                  <button
                    class="btn"
                    phx-click="permission"
                    phx-value-id={perm["id"]}
                    phx-value-decision="always"
                    id={"perm-always-#{perm["id"]}"}
                  >Always for this project</button>
                  <button
                    class="btn"
                    phx-click="permission"
                    phx-value-id={perm["id"]}
                    phx-value-decision="reject"
                    id={"perm-deny-#{perm["id"]}"}
                  >Deny</button>
                </div>
              </div>

              <div
                :if={@status == :running and @perms == []}
                id="working"
                class="flex items-center gap-2 text-[12.5px] text-muted pl-0.5"
              >
                <span class="w-1.5 h-1.5 rounded-full bg-run pulse"></span> working
              </div>
            </div>
          </div>

          <div class={["flex-none pt-3 pb-5", if(@run, do: "px-4", else: "px-6")]}>
            <div class={["relative", !@run && "max-w-[820px] mx-auto"]}>
              <%!-- `/` and `@` completion. The Composer hook draws the menu inside this
                   ignored box, so LiveView patches don't close it while you type. --%>
              <span id="slash-items" hidden data-items={Jason.encode!(@slash)}></span>
              <div
                id="composer-menu"
                phx-update="ignore"
                class="absolute bottom-full mb-2 left-0 right-0 z-20"
              >
              </div>
              <div class="flex flex-col gap-2.5 px-3.5 py-3 rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] focus-within:shadow-[inset_0_0_0_1px_#4a4952] transition">
                <div id="composer-attachments" phx-update="ignore" class="hidden flex flex-wrap gap-2">
                </div>
                <span id="composer-hint" hidden>{composer_hint(@run, @status, @project)}</span>
                <textarea
                  id="composer"
                  phx-hook=".Composer"
                  phx-update="ignore"
                  rows="1"
                  data-hint-from="composer-hint"
                  class="w-full bg-transparent outline-none resize-none text-[13.5px] leading-relaxed placeholder:text-faint max-h-[40vh]"
                ></textarea>
                <div class="flex items-center gap-1.5">
                  <.picker
                    id="agent-picker"
                    form="agent-form"
                    event="set_agent"
                    name="agent"
                    icon="hero-sparkles-micro"
                    placeholder="Pick an agent"
                    options={
                      Enum.map(
                        Enum.uniq(@agents ++ [current_agent_name(@session, @agents)]),
                        &{&1, &1}
                      )
                    }
                    value={current_agent_name(@session, @agents)}
                    title={
                      "Agent · " <>
                        Beamcode.Keybinds.label(@keybinds["agent_list"], @kb_prefs["prefix"]) <>
                        " to pick, " <>
                        Beamcode.Keybinds.label(@keybinds["agent_cycle"], @kb_prefs["prefix"]) <>
                        " to cycle"
                    }
                  />
                  <.picker
                    id="model-picker"
                    form="model-form"
                    event="set_model"
                    name="model"
                    icon="hero-cpu-chip-micro"
                    placeholder="Search models"
                    options={model_options(@models, @session)}
                    value={model_value(@session)}
                    title={
                      "Model · " <>
                        Beamcode.Keybinds.label(@keybinds["model_list"], @kb_prefs["prefix"]) <>
                        " to pick"
                    }
                  />
                  <span :if={@sending} class="text-[11.5px] text-faint ml-1">sending…</span>
                  <button
                    type="button"
                    id="send-button"
                    data-send
                    class="ml-auto font-mono text-[11px] px-2 py-1 rounded-md bg-raised text-fg hover:bg-hov transition"
                  >
                    ↵
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <aside
          :if={@diff != [] and !@run}
          id="changes"
          class="w-[380px] flex-none border-l border-line flex flex-col min-h-0"
        >
          <div class="h-11 flex-none flex items-center gap-2 px-[18px] border-b border-line text-[13px]">
            <span class="font-semibold">Changes</span>
            <span class="text-muted">{length(@diff)} {if length(@diff) == 1, do: "file", else: "files"}</span>
            <span class="ml-auto font-mono text-[12px]">
              <span class="text-add">+{Enum.sum(Enum.map(@diff, & &1["additions"]))}</span>
              <span class="text-del">−{Enum.sum(Enum.map(@diff, & &1["deletions"]))}</span>
            </span>
          </div>
          <div class="flex-1 min-h-0 overflow-y-auto">
            <%= for f <- @diff do %>
              <button
                type="button"
                id={"diff-" <> String.replace(f["file"], ~r/[^a-zA-Z0-9]/, "-")}
                phx-click="show_file"
                phx-value-file={f["file"]}
                class={[
                  "w-full flex items-center gap-2 px-[18px] py-[9px] font-mono text-[12.5px] text-left transition",
                  if(@diff_file == f["file"], do: "bg-hov", else: "hover:bg-panel")
                ]}
              >
                <span class="flex-1 truncate">{f["file"]}</span>
                <span class="text-add">+{f["additions"]}</span>
                <span class="text-del">−{f["deletions"]}</span>
              </button>
              <div
                :if={@diff_file == f["file"]}
                class="mx-3.5 my-3 py-2.5 rounded-[10px] bg-code font-mono text-[12px] leading-[1.7] overflow-x-auto"
              >
                <div
                  :for={line <- patch_lines(f["patch"])}
                  class={["flex gap-2.5 px-3 whitespace-pre", line_class(line)]}
                  phx-no-format
                >{line}</div>
              </div>
            <% end %>
          </div>
        </aside>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Elapsed">
        export default {
          mounted() {
            const start = Number(this.el.dataset.start)
            const tick = () => {
              const s = Math.max(0, Math.floor((Date.now() - start) / 1000))
              this.el.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`
            }
            tick(); this.timer = setInterval(tick, 1000)
          },
          destroyed() { clearInterval(this.timer) }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
        export default {
          mounted() {
            this.stick = true
            this.el.addEventListener("scroll", () => {
              this.stick = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
            })
            this.observer = new MutationObserver(() => { if (this.stick) this.el.scrollTop = this.el.scrollHeight })
            this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
            this.el.scrollTop = this.el.scrollHeight
            window.addEventListener("chatos:scroll", this.onScroll = (e) => {
              const h = this.el.clientHeight * 0.9
              const to = {up: this.el.scrollTop - h, down: this.el.scrollTop + h, first: 0, last: this.el.scrollHeight}[e.detail]
              this.el.scrollTo({top: to, behavior: "smooth"})
            })
          },
          destroyed() { this.observer.disconnect(); window.removeEventListener("chatos:scroll", this.onScroll) }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Picker">
        // Opens on click or on window "chatos:picker" {id} (prefix m / prefix a).
        // The menu lives on <body> so LiveView patches leave it alone.
        export default {
          mounted() {
            this.button = this.el.querySelector("button")
            this.button.addEventListener("click", () => this.menu ? this.close() : this.open())
            window.addEventListener("chatos:picker", this.onOpen = (e) => { if (e.detail?.id === this.el.id) this.open() })
          },
          destroyed() { window.removeEventListener("chatos:picker", this.onOpen); this.close() },
          open() {
            if (this.menu) return
            const select = this.el.querySelector("select")
            const options = Array.from(select.options).map(o => ({value: o.value, label: o.textContent}))
            const menu = document.createElement("div")
            menu.id = this.el.id + "-menu"
            menu.setAttribute("role", "listbox")
            menu.className = "fixed z-50 w-[300px] max-w-[calc(100vw-32px)] rounded-xl bg-panel shadow-[inset_0_0_0_1px_var(--color-line2),0_20px_50px_-20px_rgba(0,0,0,.7)] p-1.5"
            menu.style.animation = "pop-in .12s ease-out"
            const r = this.button.getBoundingClientRect()
            menu.style.left = Math.max(16, Math.min(r.left, window.innerWidth - 316)) + "px"
            menu.style.bottom = (window.innerHeight - r.top + 8) + "px"
            const input = document.createElement("input")
            input.placeholder = this.el.dataset.placeholder
            input.autocomplete = "off"
            input.spellcheck = false
            input.className = "w-full h-8 px-2.5 mb-1 rounded-lg bg-transparent outline-none text-[13px] placeholder:text-faint border-b border-line"
            const list = document.createElement("div")
            list.className = "max-h-72 overflow-y-auto flex flex-col"
            menu.append(input, list)
            let shown = [], sel = Math.max(0, options.findIndex(o => o.value === select.value))
            const render = () => {
              const q = input.value.trim().toLowerCase()
              shown = options.filter(o => !q || (o.label + " " + o.value).toLowerCase().includes(q))
              sel = Math.min(sel, Math.max(0, shown.length - 1))
              if (shown.length === 0) {
                const empty = document.createElement("div")
                empty.className = "px-2.5 py-4 text-center text-[12.5px] text-faint"
                empty.textContent = "Nothing matches."
                list.replaceChildren(empty)
                return
              }
              list.replaceChildren(...shown.map((o, i) => {
                const b = document.createElement("button")
                b.type = "button"
                b.dataset.index = i
                b.setAttribute("role", "option")
                b.setAttribute("aria-selected", i === sel ? "true" : "false")
                b.className = "w-full h-8 flex-none flex items-center gap-2 px-2.5 rounded-lg text-left text-[13px] hover:bg-hov aria-selected:bg-hov"
                const label = document.createElement("span")
                label.className = "flex-1 truncate"
                label.textContent = o.label
                const check = document.createElement("span")
                check.className = "w-3 text-[12px] text-muted"
                check.textContent = o.value === select.value ? "✓" : ""
                b.append(label, check)
                return b
              }))
              list.children[sel]?.scrollIntoView({block: "nearest"})
            }
            input.addEventListener("input", () => { sel = 0; render() })
            input.addEventListener("keydown", (e) => {
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault()
                if (shown.length) { sel = (sel + (e.key === "ArrowDown" ? 1 : -1) + shown.length) % shown.length; render() }
              } else if (e.key === "Enter") {
                e.preventDefault(); e.stopPropagation()
                shown[sel] ? this.pick(shown[sel].value) : this.close()
              } else if (e.key === "Escape" || e.key === "Tab") {
                e.preventDefault(); e.stopPropagation(); this.close(true)
              }
            })
            list.addEventListener("mousedown", (e) => {
              const b = e.target.closest("[data-index]")
              if (b) { e.preventDefault(); this.pick(shown[Number(b.dataset.index)].value) }
            })
            this.onAway = (e) => { if (!menu.contains(e.target) && !this.button.contains(e.target)) this.close() }
            document.addEventListener("mousedown", this.onAway)
            this.menu = menu
            this.button.setAttribute("aria-expanded", "true")
            document.body.append(menu)
            render()
            input.focus()
          },
          pick(value) {
            const select = this.el.querySelector("select")
            if (select.value !== value) {
              select.value = value
              select.dispatchEvent(new Event("change", {bubbles: true}))
            }
            this.close(true)
          },
          close(refocus = false) {
            if (!this.menu) return
            this.menu.remove()
            this.menu = null
            document.removeEventListener("mousedown", this.onAway)
            this.button.removeAttribute("aria-expanded")
            if (refocus) document.getElementById("composer")?.focus()
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
        export default {
          mounted() {
            const el = this.el
            const box = document.getElementById("composer-menu")
            const slashData = document.getElementById("slash-items")
            const matches = (...args) => window.ChatOSKeys.matches(...args)
            // The textarea is phx-update="ignore" (keeps what you type), so its
            // placeholder follows a hidden hint element that LiveView does update.
            const hint = document.getElementById("composer-hint")
            const syncHint = () => { el.placeholder = hint.textContent.trim() }
            syncHint()
            this.hintObserver = new MutationObserver(syncHint)
            this.hintObserver.observe(hint, {childList: true, characterData: true, subtree: true})
            const binds = () => JSON.parse(document.getElementById("app-shell").dataset.keybinds || "{}")
            const resize = () => { el.style.height = "auto"; el.style.height = Math.min(el.scrollHeight, window.innerHeight * 0.4) + "px" }
            // Completion menu for `/name` (skills, commands) and `@path` (files).
            // menu = {kind, items: [{value, label, desc, tag}], sel, start} or null.
            let menu = null, findTimer = null, findSeq = 0, askedSlash = false
            const panel = document.createElement("div")
            panel.className = "hidden max-h-64 overflow-y-auto rounded-xl bg-panel shadow-[inset_0_0_0_1px_var(--color-line2),0_20px_50px_-20px_rgba(0,0,0,.7)] p-1.5"
            box.replaceChildren(panel)
            const close = () => { menu = null; askedSlash = false; panel.classList.add("hidden") }
            const render = () => {
              if (!menu || menu.items.length === 0) { panel.classList.add("hidden"); return }
              menu.sel = Math.min(menu.sel, menu.items.length - 1)
              panel.replaceChildren(...menu.items.map((it, i) => {
                const b = document.createElement("button")
                b.type = "button"
                b.dataset.index = i
                b.className = "w-full flex items-center gap-3 h-9 px-3 rounded-lg text-left hover:bg-hov aria-selected:bg-hov"
                b.setAttribute("aria-selected", i === menu.sel ? "true" : "false")
                const label = document.createElement("span")
                label.className = "font-mono text-[13px] truncate max-w-[60%]"
                label.textContent = it.label
                const desc = document.createElement("span")
                desc.className = "flex-1 truncate text-[12.5px] text-muted"
                desc.textContent = it.desc || ""
                const tag = document.createElement("span")
                tag.className = "text-[11px] text-faint"
                tag.textContent = it.tag
                b.append(label, desc, tag)
                return b
              }))
              panel.classList.remove("hidden")
              panel.children[menu.sel]?.scrollIntoView({block: "nearest"})
            }
            const slashItems = () => { try { return JSON.parse(slashData.dataset.items || "[]") } catch (_) { return [] } }
            const updateMenu = () => {
              const before = el.value.slice(0, el.selectionStart)
              const slash = el.selectionStart === el.selectionEnd && el.value.match(/^\/([\w.-]*)$/)
              if (slash) {
                const all = slashItems()
                // OpenCode loads a folder's skills lazily; ask again if we got none.
                if (all.length === 0 && !askedSlash) { askedSlash = true; this.pushEvent("load_slash", {}) }
                const sel = menu && menu.kind === "slash" ? menu.sel : 0
                menu = {kind: "slash", sel, start: 0, items: all
                  .filter(it => it.name.startsWith(slash[1]))
                  .map(it => ({value: it.name, label: "/" + it.name, desc: it.description, tag: it.kind}))}
                render(); return
              }
              const at = el.selectionStart === el.selectionEnd && before.match(/(?:^|\s)@([^\s@]*)$/)
              if (at) {
                const query = at[1], start = el.selectionStart - query.length - 1
                if (!menu || menu.kind !== "file" || menu.start !== start) menu = {kind: "file", sel: 0, start, items: []}
                clearTimeout(findTimer)
                findTimer = setTimeout(() => {
                  const seq = ++findSeq
                  this.pushEvent("find_files", {query}, (reply) => {
                    if (seq !== findSeq || !menu || menu.kind !== "file" || menu.start !== start) return
                    menu.items = reply.items.map(f => ({value: f.path, label: f.path, desc: "", tag: f.type === "directory" ? "folder" : "file"}))
                    menu.sel = 0
                    render()
                  })
                }, 120)
                return
              }
              close()
            }
            const pick = (i) => {
              const it = menu && menu.items[i]
              if (!it) return
              if (menu.kind === "slash") {
                el.value = "/" + it.value + " "
                el.setSelectionRange(el.value.length, el.value.length)
                close()
              } else {
                // A folder keeps the menu open so you can keep going into it.
                const text = "@" + it.value + (it.tag === "folder" ? "" : " ")
                el.setRangeText(text, menu.start, el.selectionStart, "end")
                if (it.tag === "folder") updateMenu(); else close()
              }
              el.focus(); resize()
            }
            panel.addEventListener("mousedown", (e) => {
              const b = e.target.closest("[data-index]")
              if (b) { e.preventDefault(); pick(Number(b.dataset.index)) }
            })
            // Skills arrive after mount; refresh an open `/` menu when they do.
            this.slashObserver = new MutationObserver(() => { if (menu && menu.kind === "slash") updateMenu() })
            this.slashObserver.observe(slashData, {attributes: true, attributeFilter: ["data-items"]})
            el.addEventListener("blur", () => setTimeout(() => { if (document.activeElement !== el) close() }, 100))
            // Pasted or dropped images, shown as thumbnails until sent.
            const tray = document.getElementById("composer-attachments")
            let files = []
            const renderTray = () => {
              tray.classList.toggle("hidden", files.length === 0)
              tray.replaceChildren(...files.map((f, i) => {
                const wrap = document.createElement("div")
                wrap.className = "relative group"
                wrap.innerHTML = `<img class="h-16 w-16 object-cover rounded-lg shadow-[inset_0_0_0_1px_#2a2930]">` +
                  `<button type="button" title="Remove" class="absolute -top-1.5 -right-1.5 w-5 h-5 rounded-full bg-raised text-muted text-[12px] leading-5 text-center shadow hover:text-fg">×</button>`
                wrap.querySelector("img").src = f.uri
                wrap.querySelector("button").onclick = () => { files.splice(i, 1); renderTray(); el.focus() }
                return wrap
              }))
            }
            // Keep payloads small: shrink anything big to max 2000px JPEG.
            const readImage = (file) => new Promise((resolve) => {
              const reader = new FileReader()
              reader.onload = () => {
                const uri = reader.result
                if (file.size < 1_500_000) return resolve(uri)
                const img = new Image()
                img.onload = () => {
                  const scale = Math.min(1, 2000 / Math.max(img.width, img.height))
                  const c = document.createElement("canvas")
                  c.width = Math.round(img.width * scale); c.height = Math.round(img.height * scale)
                  c.getContext("2d").drawImage(img, 0, 0, c.width, c.height)
                  resolve(c.toDataURL("image/jpeg", 0.88))
                }
                img.src = uri
              }
              reader.readAsDataURL(file)
            })
            const addImages = async (list) => {
              for (const file of list) {
                if (!file.type.startsWith("image/")) continue
                const ext = (file.type.split("/")[1] || "png").replace("jpeg", "jpg")
                files.push({uri: await readImage(file), name: file.name && file.name !== "image.png" ? file.name : `pasted-${files.length + 1}.${ext}`})
              }
              renderTray()
            }
            el.addEventListener("paste", (e) => {
              const images = Array.from(e.clipboardData?.files || []).filter(f => f.type.startsWith("image/"))
              if (images.length) { e.preventDefault(); addImages(images) }
            })
            el.addEventListener("dragover", (e) => { if (e.dataTransfer?.types.includes("Files")) e.preventDefault() })
            el.addEventListener("drop", (e) => {
              const images = Array.from(e.dataTransfer?.files || []).filter(f => f.type.startsWith("image/"))
              if (images.length) { e.preventDefault(); addImages(images) }
            })

            const send = () => {
              const text = el.value
              if (!text.trim() && files.length === 0) return
              this.pushEvent("send", {text, files})
              el.value = ""
              files = []; renderTray()
              resize(); updateMenu()
            }
            document.getElementById("send-button").addEventListener("click", send)
            el.addEventListener("input", () => { resize(); updateMenu() })
            el.addEventListener("keydown", (e) => {
              const kb = binds()
              // The prefix key is armed: the next key is a shortcut, not text.
              if (window.ChatOSKeys.leaderActive()) return
              const open = menu && menu.items.length > 0 && !panel.classList.contains("hidden")
              if (open && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
                e.preventDefault()
                const n = menu.items.length
                menu.sel = (menu.sel + (e.key === "ArrowDown" ? 1 : -1) + n) % n
                render(); return
              }
              if (open && (e.key === "Tab" || e.key === "Enter") && !e.shiftKey) {
                e.preventDefault(); e.stopPropagation(); pick(menu.sel); return
              }
              if (open && e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); return }
              // Mod+Enter runs / sends everywhere; here it sends.
              if ((window.ChatOSKeys.isMac ? e.metaKey : e.ctrlKey) && e.key === "Enter") {
                e.preventDefault(); e.stopPropagation(); send(); return
              }
              if (matches(e, kb.input_newline)) {
                e.preventDefault(); e.stopPropagation()
                const s = el.selectionStart
                el.setRangeText("\n", s, el.selectionEnd, "end"); resize(); return
              }
              if (matches(e, kb.input_submit)) { e.preventDefault(); e.stopPropagation(); send(); return }
              if (matches(e, kb.input_clear) && el.selectionStart === el.selectionEnd && el.value) {
                e.preventDefault(); e.stopPropagation(); el.value = ""; resize(); updateMenu(); return
              }
              for (const action of ["agent_cycle", "agent_cycle_reverse"]) {
                if (matches(e, kb[action])) { e.preventDefault(); e.stopPropagation(); this.pushEvent("keybind", {action}); return }
              }
            })
            el.focus()
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :form, :string, required: true
  attr :event, :string, required: true
  attr :name, :string, required: true
  attr :icon, :string, required: true
  attr :placeholder, :string, required: true
  attr :options, :list, required: true, doc: "`{label, value}` pairs"
  attr :value, :string, required: true
  attr :title, :string, default: nil

  # A chip that opens a searchable menu (the .Picker hook). The hidden select
  # stays the form field, so phx-change works as with a plain select.
  defp picker(assigns) do
    assigns =
      assign(
        assigns,
        :label,
        Enum.find_value(assigns.options, assigns.value, fn {l, v} -> v == assigns.value && l end)
      )

    ~H"""
    <div id={@id} phx-hook=".Picker" data-placeholder={@placeholder} class="min-w-0">
      <form id={@form} phx-change={@event} class="hidden">
        <select name={@name} tabindex="-1">
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </form>
      <button
        type="button"
        id={@id <> "-button"}
        title={@title}
        aria-haspopup="listbox"
        class="h-7 max-w-[260px] flex items-center gap-1.5 pl-2 pr-1.5 rounded-lg text-[12px] text-soft bg-raised shadow-[inset_0_0_0_1px_var(--color-line2)] hover:text-fg hover:bg-hov aria-expanded:text-fg aria-expanded:bg-hov transition"
      >
        <.icon name={@icon} class="size-3.5 flex-none text-muted" />
        <span class="truncate">{@label}</span>
        <.icon name="hero-chevron-up-down-micro" class="size-3.5 flex-none text-faint" />
      </button>
    </div>
    """
  end

  defp transcript_prompt(msg) do
    skills = for %{"name" => n} <- msg["skills"] || [], do: "/" <> n
    Enum.join(skills ++ [msg["text"] || ""], " ")
  end

  defp run_title(run), do: BeamcodeWeb.ProjectLive.run_title(run)

  defp run_meta(run, user) do
    who = BeamcodeWeb.ProjectLive.run_who(run, user)

    case BeamcodeWeb.ProjectLive.inputs_label(run.inputs) do
      nil -> who
      inputs -> who <> " · " <> inputs
    end
  end

  # The run's own turn is still going (follow-ups after it don't count).
  defp running_run?(nil, _status), do: false
  defp running_run?(run, status), do: run.status == "running" and status in [:running, :waiting]

  defp quiet_follow_up?(assigns) do
    running_run?(assigns.run, assigns.status) and not assigns.show_transcript and
      assigns.perms == []
  end

  defp composer_hint(nil, _status, project),
    do: composer_placeholder(project) <> " · paste images"

  defp composer_hint(run, status, _project) do
    if running_run?(run, status),
      do: "Queue a follow-up…",
      else: "Ask about this run, filter, or follow up"
  end

  attr :state, :atom, required: true

  defp step_dot(assigns) do
    ~H"""
    <span class={[
      "w-[18px] h-[18px] mt-px flex-none rounded-full flex items-center justify-center text-[11px]",
      @state == :done && "bg-add text-canvas",
      @state == :failed && "bg-del text-canvas",
      @state == :current && "shadow-[inset_0_0_0_2px_var(--color-run)]",
      @state == :pending && "shadow-[inset_0_0_0_1.5px_var(--color-line3)]"
    ]}>
      <span :if={@state == :done}>✓</span>
      <span :if={@state == :failed}>×</span>
      <span :if={@state == :current} class="w-1.5 h-1.5 rounded-full bg-run pulse"></span>
    </span>
    """
  end

  attr :run, :map, required: true
  attr :status, :atom, required: true

  defp run_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% @status in [:running, :waiting] -> %>
        <Layouts.status_badge status={@status} />
      <% @run.status == "failed" -> %>
        <span class="h-5 flex items-center px-[7px] rounded-md bg-delbg text-del text-[11.5px]">failed</span>
      <% true -> %>
        <span class="h-5 flex items-center px-[7px] rounded-md bg-addbg text-add text-[11.5px]">done</span>
    <% end %>
    """
  end

  defp composer_placeholder(%{kind: "chat"}), do: "Ask anything"
  defp composer_placeholder(%{kind: "system"}), do: "Reply, or paste docs for an API to connect"
  defp composer_placeholder(_), do: "Reply, or / for commands and skills"

  defp current_agent_name(session, agents), do: session["agent"] || List.first(agents) || "build"

  defp model_value(%{"model" => %{"id" => id, "providerID" => p}}), do: "#{p}/#{id}"
  defp model_value(_), do: ""

  defp model_options(models, session) do
    current = model_value(session)

    if current != "" and not Enum.any?(models, fn {_, v} -> v == current end),
      do: [{session["model"]["id"], current} | models],
      else: if(current == "", do: [{"default model", ""} | models], else: models)
  end

  defp location_label(session, project) do
    case get_in(session, ["location", "directory"]) do
      nil -> ""
      dir when dir == project.directory -> ""
      dir -> " · " <> Path.basename(dir)
    end
  end

  defp patch_lines(nil), do: []

  defp patch_lines(patch) do
    patch
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
    |> Enum.take(400)
  end

  defp line_class("+" <> _), do: "bg-addbg text-add"
  defp line_class("-" <> _), do: "bg-delbg text-del"
  defp line_class("@@" <> _), do: "text-faint"
  defp line_class(_), do: "text-muted"

  ## Messages

  attr :msg, :map, required: true

  defp message(%{msg: %{"_view" => "hidden"}} = assigns), do: ~H""

  defp message(%{msg: %{"_view" => view}} = assigns) when view in ["card", "card_open"] do
    ~H"""
    <div class="flex flex-col gap-3.5">
      <button
        type="button"
        id="run-transcript"
        phx-click="toggle_transcript"
        class="w-full flex items-center gap-2.5 px-3 py-2.5 rounded-[10px] text-left shadow-[inset_0_0_0_1px_var(--color-line)] hover:bg-panel transition"
      >
        <span class={[
          "text-faint text-[11px] transition",
          @msg["_view"] == "card_open" && "rotate-90"
        ]}>▸</span>
        <span class="flex-1 min-w-0 flex flex-col">
          <span class="text-[13px]">Run transcript</span>
          <span class="font-mono text-[11.5px] text-muted truncate">
            {String.slice(transcript_prompt(@msg), 0, 80)} · {@msg["_tools"]} tool calls
          </span>
        </span>
      </button>
      <.message :if={@msg["_view"] == "card_open"} msg={Map.delete(@msg, "_view")} />
    </div>
    """
  end

  defp message(%{msg: %{"type" => "user"}} = assigns) do
    ~H"""
    <div class="flex flex-col items-end gap-1">
      <div
        :if={@msg["text"] not in [nil, ""]}
        class="max-w-[76%] px-[13px] py-[9px] rounded-xl bg-raised text-[13.5px] whitespace-pre-wrap text-pretty break-words"
        phx-no-format
      >{@msg["text"]}</div>
      <div :if={images(@msg) != []} class="flex flex-wrap justify-end gap-2 max-w-[76%]">
        <a
          :for={img <- images(@msg)}
          href={img}
          target="_blank"
          class="block rounded-lg overflow-hidden shadow-[inset_0_0_0_1px_var(--color-line)] hover:opacity-90 transition"
        >
          <img src={img} class="max-h-48 max-w-[320px] object-contain bg-code" alt="pasted image" />
        </a>
      </div>
      <div :if={(@msg["skills"] || []) != []} class="text-[11.5px] text-faint font-mono">
        /{Enum.map_join(@msg["skills"], " /", & &1["name"])}
      </div>
    </div>
    """
  end

  defp message(%{msg: %{"type" => "assistant"}} = assigns) do
    assigns = assign(assigns, :groups, group_parts(assigns.msg["content"] || []))

    ~H"""
    <div class="flex flex-col gap-2.5">
      <%= for {kind, part} <- @groups do %>
        <%= case kind do %>
          <% :reasoning -> %>
            <details class="group text-[12.5px] text-faint">
              <summary class="cursor-pointer list-none hover:text-muted select-none">
                Thinking
              </summary>
              <div class="mt-1 pl-3 border-l border-line whitespace-pre-wrap">{part["text"]}</div>
            </details>
          <% :text -> %>
            <div class="md">{Markdown.to_html(part["text"])}</div>
          <% :tools -> %>
            <details class="group">
              <summary class="cursor-pointer list-none font-mono text-[12px] leading-relaxed text-muted hover:text-fg select-none">
                {tools_summary(part)}
              </summary>
              <div class="mt-2 flex flex-col gap-2">
                <div
                  :for={t <- part}
                  class="rounded-[10px] bg-code shadow-[inset_0_0_0_1px_var(--color-line)] overflow-hidden"
                >
                  <div class="px-3 py-1.5 font-mono text-[12px] text-soft border-b border-line flex gap-2">
                    <span class="truncate">{tool_label(t)}</span>
                    <span class={["ml-auto", tool_status_class(t)]}>{get_in(t, ["state", "status"])}</span>
                  </div>
                  <pre class="px-3 py-2 font-mono text-[11.5px] leading-relaxed text-muted whitespace-pre-wrap break-all max-h-64 overflow-y-auto">{tool_output(t)}</pre>
                </div>
              </div>
            </details>
        <% end %>
      <% end %>
      <div :if={@msg["error"]} class="text-[13px] text-del">
        {@msg["error"]["message"]}
      </div>
    </div>
    """
  end

  defp message(%{msg: %{"type" => "shell"}} = assigns) do
    ~H"""
    <div class="rounded-[10px] bg-code shadow-[inset_0_0_0_1px_var(--color-line)] overflow-hidden">
      <div class="px-3 py-1.5 font-mono text-[12px] text-soft border-b border-line">
        $ {@msg["command"]}
      </div>
      <pre class="px-3 py-2 font-mono text-[11.5px] text-muted whitespace-pre-wrap max-h-64 overflow-y-auto">{get_in(@msg, ["output", "output"])}</pre>
    </div>
    """
  end

  defp message(%{msg: %{"type" => "idle"}} = assigns) do
    ~H"""
    <div class="text-[12px] text-faint">Stopped · {@msg["outcome"]}</div>
    """
  end

  defp message(%{msg: %{"type" => type}} = assigns)
       when type in [
              "model-switched",
              "agent-switched",
              "location-switched",
              "skill",
              "compaction"
            ] do
    ~H"""
    <div class="text-[12px] text-faint font-mono">{meta_line(@msg)}</div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div :if={@msg["text"]} class="text-[12.5px] text-faint whitespace-pre-wrap">{@msg["text"]}</div>
    """
  end

  defp images(msg) do
    for %{"mime" => "image/" <> _ = mime, "data" => data} <- msg["files"] || [],
        do: "data:#{mime};base64,#{data}"
  end

  defp meta_line(%{"type" => "model-switched"} = m), do: "→ model #{get_in(m, ["model", "id"])}"
  defp meta_line(%{"type" => "agent-switched"} = m), do: "→ agent #{m["agent"]}"
  defp meta_line(%{"type" => "location-switched"}), do: "→ moved"
  defp meta_line(%{"type" => "skill"} = m), do: "ran skill /#{m["name"] || m["skill"]}"
  defp meta_line(%{"type" => "compaction"}), do: "compacted"
  defp meta_line(_), do: ""

  defp group_parts(parts) do
    parts
    |> Enum.chunk_by(&(&1["type"] == "tool"))
    |> Enum.flat_map(fn
      [%{"type" => "tool"} | _] = tools -> [{:tools, tools}]
      others -> Enum.map(others, &{part_kind(&1["type"]), &1})
    end)
    |> Enum.filter(fn {k, p} ->
      k in [:text, :reasoning, :tools] and (k == :tools or (p["text"] || "") != "")
    end)
  end

  defp part_kind("text"), do: :text
  defp part_kind("reasoning"), do: :reasoning
  defp part_kind(_), do: :other

  defp tools_summary(tools) do
    names = tools |> Enum.map(&short_tool/1) |> Enum.uniq() |> Enum.take(4) |> Enum.join(", ")
    n = length(tools)
    "#{n} tool #{if n == 1, do: "call", else: "calls"} · #{names}"
  end

  defp short_tool(t) do
    input = tool_input(t)

    case t["name"] do
      "read" ->
        "Read #{short_path(input["path"] || input["filePath"])}"

      "shell" ->
        "Shell `#{String.slice(input["command"] || "", 0, 40)}`"

      n when n in ["edit", "write", "apply_patch", "patch"] ->
        "Edit #{short_path(input["path"] || input["filePath"])}"

      "grep" ->
        "Grep “#{input["pattern"]}”"

      "glob" ->
        "Glob #{input["pattern"]}"

      "webfetch" ->
        "Fetch #{input["url"]}"

      "gateway_" <> rest ->
        String.replace(rest, "_", " · ", global: false)

      "execute" ->
        code_mode_label(input["code"] || "")

      name ->
        name
    end
  end

  # While a call streams, OpenCode sends its input as a partial JSON string.
  defp tool_input(t) do
    case get_in(t, ["state", "input"]) do
      %{} = input -> input
      _ -> %{}
    end
  end

  defp short_path(nil), do: ""
  defp short_path(path), do: Path.basename(path)

  # Code mode wraps MCP calls in one `execute` tool; name what it called.
  defp code_mode_label(code) do
    case Regex.scan(~r/tools\.(\w+)\.(\w+)/, code) do
      [] -> if String.contains?(code, "search("), do: "Find tools", else: "Run code"
      calls -> calls |> Enum.map(fn [_, _ns, name] -> name end) |> Enum.uniq() |> Enum.join(", ")
    end
  end

  defp tool_label(t) do
    input = tool_input(t)
    "#{t["name"]} #{input |> Jason.encode!() |> String.slice(0, 200)}"
  end

  defp tool_status_class(t) do
    case get_in(t, ["state", "status"]) do
      "completed" -> "text-add"
      "error" -> "text-del"
      _ -> "text-run"
    end
  end

  defp tool_output(t) do
    state = t["state"] || %{}

    content =
      (state["content"] || [])
      |> Enum.map_join("\n", fn
        %{"type" => "text", "text" => text} -> text
        %{"type" => "file"} = f -> "[file #{f["name"] || f["uri"]}]"
        other -> inspect(other)
      end)

    text =
      if state["error"], do: state["error"]["message"] || inspect(state["error"]), else: content

    String.slice(text || "", 0, 8000)
  end
end
