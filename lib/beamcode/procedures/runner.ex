defmodule Beamcode.Procedures.Runner do
  @moduledoc """
  Moves procedure runs on when a step's session stops (see `Beamcode.Procedures.Runs.session_idle/2`).
  Every 30 seconds it also looks for steps whose session stopped while
  Peon wasn't listening (a restart, a dropped event stream): one still idle on
  two looks in a row is moved on as if its session had just stopped.
  """
  use GenServer
  require Logger
  alias Beamcode.Opencode.Events
  alias Beamcode.Procedures.Runs

  @sweep_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Events.subscribe_activity()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{idle: MapSet.new()}}
  end

  @impl true
  def handle_info({:oc_activity, "session.execution." <> result, %{"sessionID" => sid}}, state)
      when result in ["succeeded", "failed", "interrupted"] do
    outcome = if result == "succeeded", do: :ok, else: :failed
    idle(sid, outcome)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)

    idle =
      if Events.connected?(),
        do: MapSet.new(Runs.stalled_steps(&(Events.status(&1) != :idle))),
        else: MapSet.new()

    for {_run, _step, sid} = key <- idle, MapSet.member?(state.idle, key) do
      Logger.info("procedure runner: moving on a step whose end was missed (#{sid})")
      idle(sid, :ok)
    end

    {:noreply, %{state | idle: idle}}
  rescue
    e ->
      Logger.error("procedure runner sweep: " <> Exception.message(e))
      {:noreply, state}
  catch
    :exit, _ -> {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Reads the transcript and sends the next step; keep this process free.
  defp idle(sid, outcome) do
    Task.start(fn ->
      try do
        Runs.session_idle(sid, outcome)
      rescue
        e -> Logger.error("procedure runner: " <> Exception.format(:error, e, __STACKTRACE__))
      end
    end)
  end
end
