defmodule Beamcode.SchedulesTest do
  use ExUnit.Case, async: true
  alias Beamcode.Schedules

  test "run titles carry the schedule's name" do
    at = ~N[2026-10-09 18:09:00]
    assert Schedules.run_title("morning-digest", at) == "morning-digest · Fri 9 Oct 18:09"
    assert Schedules.run_title("manual", at) == "Run · Fri 9 Oct 18:09"
  end
end
