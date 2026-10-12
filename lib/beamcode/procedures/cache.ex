defmodule Beamcode.Procedures.Cache do
  @moduledoc """
  Keeps each Folder's procedure list for a few seconds, so a run's steps, `/`
  completion and the scheduler don't all re-read the files over OpenCode.
  `config :beamcode, :procedures_cache_ms` sets how long (0 turns it off).
  """
  use GenServer

  @table :procedures_cache

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @doc "The cached value for `key`, else `fun.()` (kept for the configured time)."
  def fetch(key, fun) do
    ttl = Application.get_env(:beamcode, :procedures_cache_ms, 15_000)
    now = System.monotonic_time(:millisecond)

    case ttl > 0 && lookup(key) do
      {at, value} when now - at < ttl ->
        value

      _ ->
        value = fun.()
        if ttl > 0, do: put(key, now, value)
        value
    end
  end

  @doc "Forgets `key` (after its files changed)."
  def drop(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{_, at, value}] -> {at, value}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp put(key, at, value) do
    :ets.insert(@table, {key, at, value})
  rescue
    ArgumentError -> :ok
  end
end
