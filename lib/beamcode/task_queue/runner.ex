defmodule Beamcode.TaskQueue.Runner do
  @moduledoc "Starts a worktree's next task when its chat stops (see `Beamcode.TaskQueue.finished/1`)."
  use GenServer
  alias Beamcode.Opencode.Events
  alias Beamcode.TaskQueue

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Events.subscribe_activity()
    {:ok, nil}
  end

  @impl true
  def handle_info({:oc_activity, "session.execution.succeeded", %{"sessionID" => sid}}, state) do
    # Reads tickets over the OpenCode API; keep this process free.
    Task.start(fn -> TaskQueue.finished(sid) end)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
