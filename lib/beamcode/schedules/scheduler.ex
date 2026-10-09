defmodule Beamcode.Schedules.Scheduler do
  @moduledoc """
  Ticks once a minute. Bootstraps the workspace, keeps connector permissions in
  sync, and starts schedule runs whose cron matches the current local minute.
  Also marks runs done when their session stops.
  """
  use GenServer
  require Logger
  alias Beamcode.{Connectors, Projects, Schedules, Workspace}
  alias Beamcode.Opencode.Events
  alias Beamcode.Schedules.Cron

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Events.subscribe_activity()
    :ets.new(:schedule_summary, [:named_table, :public, read_concurrency: true])
    if Keyword.get(opts, :tick, true), do: send(self(), :tick)
    {:ok, %{last_minute: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = Cron.local_now()
    minute = %{now | second: 0, microsecond: {0, 0}}
    Process.send_after(self(), :tick, (60 - now.second) * 1000 + 50)

    if minute != state.last_minute do
      Task.start(fn -> tick(minute) end)
    end

    {:noreply, %{state | last_minute: minute}}
  end

  def handle_info({:oc_activity, "session.execution." <> result, %{"sessionID" => sid}}, state) do
    status =
      case result do
        "succeeded" -> "done"
        "started" -> nil
        _ -> "failed"
      end

    # Summaries fetch the transcript; keep the scheduler free.
    if status, do: Task.start(fn -> Schedules.session_finished(sid, status) end)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp tick(minute) do
    if Workspace.ensure_bootstrap() == :ok do
      Connectors.sync_all()

      for project <- Projects.list_projects(), {:ok, scheds} <- [Schedules.read(project)] do
        Schedules.put_summary(project.id, scheds)

        for {key, sched} <- scheds,
            {:ok, cron} <- [Cron.parse(sched["cron"])],
            Cron.matches?(cron, minute) do
          Logger.info("running schedule #{project.name}/#{key}")
          Schedules.run(project, key, sched)
        end
      end
    end
  rescue
    e -> Logger.error("scheduler tick failed: " <> Exception.format(:error, e, __STACKTRACE__))
  end
end
