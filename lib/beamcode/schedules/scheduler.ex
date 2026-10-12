defmodule Beamcode.Schedules.Scheduler do
  @moduledoc """
  Ticks once a minute. Bootstraps the workspace, keeps connector permissions in
  sync, and starts schedule runs whose cron matches the current local minute:
  `schedules.json` entries, and procedures with a `schedule:` in their file.
  On the first tick after a start, a procedure whose last slot passed while
  Peon was down runs once. Also marks runs done when their session stops.
  """
  use GenServer
  require Logger
  import Ecto.Query, only: [from: 2]
  alias Beamcode.{Accounts, Connectors, Procedures, Projects, Repo, Schedules, Workspace}
  alias Beamcode.Procedures.Runs
  alias Beamcode.Schedules.Run
  alias Beamcode.Opencode.Events
  alias Beamcode.Schedules.Cron

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Events.subscribe_activity()
    :ets.new(:schedule_summary, [:named_table, :public, read_concurrency: true])
    if Keyword.get(opts, :tick, true), do: send(self(), :tick)
    {:ok, %{last_minute: nil, caught_up: false}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = Cron.local_now()
    minute = %{now | second: 0, microsecond: {0, 0}}
    Process.send_after(self(), :tick, (60 - now.second) * 1000 + 50)

    catch_up = not state.caught_up

    if minute != state.last_minute do
      Task.start(fn -> tick(minute, catch_up) end)
    end

    {:noreply, %{state | last_minute: minute, caught_up: true}}
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

  defp tick(minute, catch_up) do
    if Workspace.ensure_bootstrap() == :ok do
      Connectors.sync_all()

      for project <- Projects.list_projects(), {:ok, scheds} <- [Schedules.read(project)] do
        Schedules.put_summary(project.id, scheds)

        for {key, sched} <- scheds,
            sched["paused"] != true,
            {:ok, cron} <- [Cron.parse(sched["cron"])],
            Cron.matches?(cron, minute) do
          Logger.info("running schedule #{project.name}/#{key}")
          Schedules.run(project, key, sched)
        end

        procedure_schedules(project, minute, catch_up)
      end
    end
  rescue
    e -> Logger.error("scheduler tick failed: " <> Exception.format(:error, e, __STACKTRACE__))
  end

  # Procedures whose file has a schedule, unless paused in Peon. A slot is
  # skipped while the last scheduled run of it is still going.
  defp procedure_schedules(project, minute, catch_up) do
    for p <- Procedures.list(project),
        p.schedule && p.schedule.cron,
        p.name not in (project.paused_schedules || []),
        {:ok, cron} <- [Cron.parse(p.schedule.cron)],
        Cron.matches?(cron, minute) or (catch_up and missed?(project, p, cron, minute)),
        not going?(project, p) do
      Logger.info("running procedure #{project.name}/#{p.name} on its schedule")
      owner = project.owner_id && Accounts.get_user(project.owner_id)

      Runs.start(project, owner, p, %{}, trigger: "schedule", key: p.name)
    end
  end

  defp last_scheduled(project, p) do
    from(r in Run,
      where: r.project_id == ^project.id and r.procedure == ^p.name and r.trigger == "schedule",
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp going?(project, p), do: match?(%{status: s} when s in ["running", "waiting"], last_scheduled(project, p))

  # Whether the latest slot in the last week came and went with no run.
  @doc false
  def missed?(project, p, cron, minute) do
    slot =
      Stream.iterate(NaiveDateTime.add(minute, -60), &NaiveDateTime.add(&1, -60))
      |> Stream.take(7 * 24 * 60)
      |> Enum.find(&Cron.matches?(cron, &1))

    case {slot, last_scheduled(project, p)} do
      {nil, _} -> false
      {_, nil} -> false
      {slot, run} -> NaiveDateTime.compare(local(run.inserted_at), slot) == :lt
    end
  end

  defp local(%DateTime{} = utc) do
    utc
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end
end
