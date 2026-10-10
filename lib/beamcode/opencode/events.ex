defmodule Beamcode.Opencode.Events do
  @moduledoc """
  Holds one SSE connection to `/api/event` and rebroadcasts on PubSub:

    * `"oc:session:<id>"` – every event for that session, as `{:oc_event, type, data}`
    * `"oc:activity"` – `{:oc_activity, type, data}` for status changes only

  Also tracks which sessions are running and which permission requests are
  pending, in ETS, so lists and the Inbox can read them without polling.
  """
  use GenServer
  require Logger
  alias Beamcode.Opencode

  @status :oc_session_status
  @perms :oc_pending_permissions
  @info :oc_session_info
  @activity ~w(session.created session.renamed session.deleted session.execution.started
               session.execution.succeeded session.execution.failed session.execution.interrupted
               permission.asked permission.replied)

  @message_changes ~w(session.inbox.delivered session.tool.called session.tool.success
                      session.tool.failed session.tool.error session.text.ended
                      session.reasoning.ended session.step.ended session.step.failed
                      session.agent.selected session.model.selected session.compaction.completed
                      session.shell.ended session.skill.completed)

  @doc "Whether a session event means its stored messages changed, so they are worth fetching again."
  def messages_changed?(type),
    do: type in @message_changes or String.starts_with?(type, "session.execution.")

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe_session(id), do: Phoenix.PubSub.subscribe(Beamcode.PubSub, "oc:session:" <> id)

  def unsubscribe_session(id),
    do: Phoenix.PubSub.unsubscribe(Beamcode.PubSub, "oc:session:" <> id)

  def subscribe_activity, do: Phoenix.PubSub.subscribe(Beamcode.PubSub, "oc:activity")

  @doc "Returns :running, :waiting or :idle."
  def status(session_id) do
    cond do
      pending_for(session_id) != [] -> :waiting
      :ets.member(@status, session_id) -> :running
      true -> :idle
    end
  rescue
    ArgumentError -> :idle
  end

  def running_ids do
    :ets.tab2list(@status) |> Enum.map(&elem(&1, 0))
  rescue
    ArgumentError -> []
  end

  def pending_permissions do
    :ets.tab2list(@perms) |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  def pending_for(session_id) do
    :ets.match_object(@perms, {:_, %{"sessionID" => session_id}}) |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  def connected?, do: GenServer.call(__MODULE__, :connected?)

  @doc "Session info from OpenCode, cached until the session is renamed or deleted."
  def session_info(id) do
    case :ets.lookup(@info, id) do
      [{^id, info}] ->
        info

      [] ->
        case Opencode.get_session(id) do
          {:ok, s} ->
            :ets.insert(@info, {id, s})
            s

          _ ->
            nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  ## Server

  @impl true
  def init(_) do
    :ets.new(@status, [:named_table, :public, read_concurrency: true])
    :ets.new(@perms, [:named_table, :public, read_concurrency: true])
    :ets.new(@info, [:named_table, :public, read_concurrency: true])
    send(self(), :connect)
    {:ok, %{task: nil, buffer: "", connected: false}}
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.connected, state}

  @impl true
  def handle_info(:connect, state) do
    parent = self()

    task =
      Task.async(fn ->
        Opencode.req(receive_timeout: :infinity)
        |> Req.get(
          url: "/api/event",
          headers: [{"accept", "text/event-stream"}],
          into: fn {:data, chunk}, acc ->
            send(parent, {:sse, chunk})
            {:cont, acc}
          end
        )
      end)

    {:noreply, %{state | task: task, buffer: ""}}
  end

  def handle_info({:sse, chunk}, state) do
    state = if state.connected, do: state, else: on_connected(state)
    {events, rest} = parse(state.buffer <> chunk)
    Enum.each(events, &dispatch/1)
    {:noreply, %{state | buffer: rest}}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, %Req.Response{status: 200}} -> Logger.info("opencode event stream ended")
      other -> Logger.warning("opencode event stream: #{inspect(other, limit: 5)}")
    end

    {:noreply, reconnect(state)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("opencode event stream crashed: #{inspect(reason, limit: 5)}")
    {:noreply, reconnect(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp reconnect(state) do
    Process.send_after(self(), :connect, 3_000)

    if state.connected,
      do:
        Phoenix.PubSub.broadcast(
          Beamcode.PubSub,
          "oc:activity",
          {:oc_activity, "disconnected", %{}}
        )

    %{state | task: nil, connected: false, buffer: ""}
  end

  defp on_connected(state) do
    # Rebuild running/waiting state from the server, since we may have missed events.
    :ets.delete_all_objects(@status)
    :ets.delete_all_objects(@perms)

    with {:ok, active} when is_map(active) <- Opencode.active_sessions() do
      for {sid, _} <- active do
        :ets.insert(@status, {sid, true})

        with {:ok, perms} <- Opencode.session_permissions(sid) do
          Enum.each(perms, &:ets.insert(@perms, {&1["id"], &1}))
        end
      end
    end

    Phoenix.PubSub.broadcast(Beamcode.PubSub, "oc:activity", {:oc_activity, "connected", %{}})
    %{state | connected: true}
  end

  defp parse(buffer) do
    parts = String.split(buffer, ~r/\r?\n\r?\n/)
    {complete, [rest]} = Enum.split(parts, -1)

    events =
      Enum.flat_map(complete, fn block ->
        data =
          block
          |> String.split(~r/\r?\n/)
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map_join(
            "\n",
            &(&1 |> String.replace_prefix("data:", "") |> String.trim_leading())
          )

        case Jason.decode(data) do
          {:ok, json} when is_map(json) -> [json]
          _ -> []
        end
      end)

    {events, rest}
  end

  defp dispatch(%{"type" => type} = event) do
    data = Map.get(event, "data") || %{}
    track(type, data, event)
    sid = data["sessionID"]

    if sid,
      do: Phoenix.PubSub.broadcast(Beamcode.PubSub, "oc:session:" <> sid, {:oc_event, type, data})

    if type in @activity,
      do: Phoenix.PubSub.broadcast(Beamcode.PubSub, "oc:activity", {:oc_activity, type, data})
  end

  defp dispatch(_), do: :ok

  defp track("session.execution.started", %{"sessionID" => sid}, _),
    do: :ets.insert(@status, {sid, true})

  defp track("session.execution." <> _, %{"sessionID" => sid}, _) do
    :ets.delete(@status, sid)
    :ets.match_delete(@perms, {:_, %{"sessionID" => sid}})
  end

  defp track("permission.asked", %{"id" => id} = data, event) do
    :ets.insert(@perms, {id, Map.put(data, "location", event["location"])})
  end

  defp track("permission.replied", %{"requestID" => id}, _), do: :ets.delete(@perms, id)

  defp track("session.renamed", %{"sessionID" => sid, "title" => title}, _) do
    case :ets.lookup(@info, sid) do
      [{^sid, info}] -> :ets.insert(@info, {sid, Map.put(info, "title", title)})
      _ -> :ok
    end
  end

  defp track("session.deleted", %{"sessionID" => sid}, _), do: :ets.delete(@info, sid)
  defp track(_, _, _), do: :ok
end
