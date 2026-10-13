defmodule Beamcode.SourceSync.Ticker do
  @moduledoc """
  Pulls every Dataset's synced sources (connectors, API tables) in the background, each as often as
  its `every_minutes` (5 by default). Checks once a minute.
  """
  use GenServer
  require Logger
  alias Beamcode.{DataSources, Projects}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, 20_000)
    {:ok, %{last: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 60_000)
    now = System.monotonic_time(:second)

    due =
      for project <- Projects.list_projects(),
          project.kind == "dataset",
          {name, s} <- DataSources.connector_sources(project),
          # An API table waits for its token rather than failing every minute.
          DataSources.ready?(project, s),
          last = state.last[{project.id, name}],
          last == nil or now - last >= s.every_minutes * 60 do
        {project, name}
      end

    for {project, name} <- due do
      Task.Supervisor.start_child(Beamcode.TaskSupervisor, fn ->
        case DataSources.refresh(project, name) do
          :ok -> :ok
          {:error, reason} -> Logger.info("sync #{project.name}/#{name}: #{reason}")
        end
      end)
    end

    last = Enum.reduce(due, state.last, fn {p, name}, acc -> Map.put(acc, {p.id, name}, now) end)
    {:noreply, %{state | last: last}}
  rescue
    e ->
      Logger.error("source sync tick failed: " <> Exception.message(e))
      {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
