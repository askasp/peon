defmodule Beamcode.Connectors.Limiter do
  @moduledoc """
  Paces calls per connector when its file sets `"rateLimit": {"perMinute": N}`,
  so every session and run together stay under the API's limit.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Blocks until a call to `name` fits in the last minute's budget."
  def acquire(_name, nil), do: :ok

  def acquire(name, per_minute) when is_integer(per_minute) and per_minute > 0 do
    case GenServer.call(__MODULE__, {:acquire, name, per_minute}) do
      :ok ->
        :ok

      {:wait, ms} ->
        Process.sleep(ms)
        acquire(name, per_minute)
    end
  catch
    # Not running (tests) or overloaded: don't block the call.
    :exit, _ -> :ok
  end

  def acquire(_name, _), do: :ok

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:acquire, name, per_minute}, _from, state) do
    now = System.monotonic_time(:millisecond)
    recent = state |> Map.get(name, []) |> Enum.filter(&(now - &1 < 60_000))

    if length(recent) < per_minute do
      {:reply, :ok, Map.put(state, name, [now | recent])}
    else
      oldest = Enum.min(recent)
      {:reply, {:wait, 60_000 - (now - oldest) + 50}, Map.put(state, name, recent)}
    end
  end
end
