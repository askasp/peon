defmodule Beamcode.Instrument do
  @moduledoc """
  Timing for the gateway's slow paths: OpenCode calls, channel work and joins.

  Every span is emitted as `[:beamcode, :span, :stop]` (measurements
  `%{duration}`, metadata `%{label: label, …}`) and logged: `debug` for all
  spans, `warning` once one passes `:log_slow_ms`
  (`config :beamcode, :log_slow_ms`, default 300).

  Grep the logs for `slow span` to see what held a request up:

      slow span channel session:ses_ecfe8d175ffeSvziMp7OnJqGGb 412ms status=200
      slow span session:load_diff files=53 351ms
      slow span oc GET /api/session/ses_ecfe8d175ffeSvziMp7OnJqGGb/diff status=200 168ms bytes=7778076
  """
  require Logger

  @doc "The threshold, in milliseconds, past which a span is logged as a warning."
  def slow_ms, do: Application.get_env(:beamcode, :log_slow_ms, 300)

  @doc "Times `fun` under `label`, logging it and returning its result unchanged."
  def span(label, fun) when is_binary(label) and is_function(fun, 0),
    do: span(label, %{}, fun)

  def span(label, meta, fun) when is_binary(label) and is_map(meta) and is_function(fun, 0) do
    start = System.monotonic_time()
    result = fun.()
    report(label, System.monotonic_time() - start, meta)
    result
  end

  @doc "Logs and emits a span that was already measured (`elapsed` in native units)."
  def report(label, elapsed, meta \\ %{}) when is_binary(label) and is_map(meta) do
    :telemetry.execute(
      [:beamcode, :span, :stop],
      %{duration: elapsed},
      Map.put(meta, :label, label)
    )

    ms = System.convert_time_unit(elapsed, :native, :microsecond) / 1000
    line = "#{label} #{format_ms(ms)}#{suffix(meta)}"

    if ms >= slow_ms(),
      do: Logger.warning("slow span #{line}"),
      else: Logger.debug("span #{line}")

    :ok
  end

  defp format_ms(ms) when ms >= 1000, do: :erlang.float_to_binary(ms / 1000, decimals: 2) <> "s"
  defp format_ms(ms), do: :erlang.float_to_binary(ms, decimals: 1) <> "ms"

  defp suffix(meta) when map_size(meta) == 0, do: ""
  defp suffix(meta), do: " " <> Enum.map_join(meta, " ", fn {k, v} -> "#{k}=#{v}" end)
end
