defmodule Beamcode.Procedures.Runner do
  @moduledoc "Moves procedure runs on when a step's session stops (see `Beamcode.Procedures.Runs.session_idle/2`)."
  use GenServer
  require Logger
  alias Beamcode.Opencode.Events
  alias Beamcode.Procedures.Runs

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Events.subscribe_activity()
    {:ok, nil}
  end

  @impl true
  def handle_info({:oc_activity, "session.execution." <> result, %{"sessionID" => sid}}, state)
      when result in ["succeeded", "failed", "interrupted"] do
    outcome = if result == "succeeded", do: :ok, else: :failed

    # Reads the transcript and sends the next step; keep this process free.
    Task.start(fn ->
      try do
        Runs.session_idle(sid, outcome)
      rescue
        e -> Logger.error("procedure runner: " <> Exception.format(:error, e, __STACKTRACE__))
      end
    end)

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
