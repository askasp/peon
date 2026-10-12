defmodule Beamcode.InstrumentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  test "span returns the function's result" do
    assert Beamcode.Instrument.span("demo", fn -> {:ok, 1} end) == {:ok, 1}
  end

  test "a span past the threshold is logged as a slow warning" do
    Application.put_env(:beamcode, :log_slow_ms, 0)
    on_exit(fn -> Application.delete_env(:beamcode, :log_slow_ms) end)

    log = capture_log(fn -> Beamcode.Instrument.span("demo", fn -> :ok end) end)
    assert log =~ "slow span demo"
  end

  test "emits [:beamcode, :span, :stop] with the label and metadata" do
    handler_id = "instrument-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:beamcode, :span, :stop],
      fn _event, measurements, metadata, _config ->
        send(parent, {:span, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Beamcode.Instrument.span("demo", %{status: 200}, fn -> :ok end)

    assert_receive {:span, %{duration: duration}, %{label: "demo", status: 200}}
    assert is_integer(duration)
  end
end
