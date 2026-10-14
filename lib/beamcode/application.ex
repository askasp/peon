defmodule Beamcode.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BeamcodeWeb.Telemetry,
        Beamcode.Repo,
        {DNSCluster, query: Application.get_env(:beamcode, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Beamcode.PubSub},
        {Task.Supervisor, name: Beamcode.TaskSupervisor},
        Beamcode.Connectors.Limiter,
        Beamcode.Procedures.Cache,
        {Beamcode.GitFetch, tick: Application.get_env(:beamcode, :start_workers, true)}
      ] ++
        workers() ++
        [
          # Start to serve requests, typically the last entry
          BeamcodeWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Beamcode.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp workers do
    if Application.get_env(:beamcode, :start_workers, true) do
      [
        Beamcode.Opencode.Events,
        Beamcode.Schedules.Scheduler,
        Beamcode.SourceSync.Ticker,
        Beamcode.TaskQueue.Runner,
        Beamcode.Procedures.Runner
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BeamcodeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
