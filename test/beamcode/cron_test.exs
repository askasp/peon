defmodule Beamcode.Schedules.CronTest do
  use ExUnit.Case, async: true
  alias Beamcode.Schedules.Cron

  test "parses common lines and rejects bad ones" do
    assert {:ok, _} = Cron.parse("0 8 * * 1-5")
    assert {:ok, _} = Cron.parse("*/30 * * * *")
    assert {:ok, _} = Cron.parse("5,35 9-17 1 * 0")
    assert {:error, _} = Cron.parse("0 8 * *")
    assert {:error, _} = Cron.parse("61 * * * *")
    assert {:error, _} = Cron.parse("a b c d e")
  end

  test "matches weekdays at 08:00" do
    {:ok, cron} = Cron.parse("0 8 * * 1-5")
    # 2026-10-09 is a Friday, 2026-10-10 a Saturday
    assert Cron.matches?(cron, ~N[2026-10-09 08:00:00])
    refute Cron.matches?(cron, ~N[2026-10-09 08:01:00])
    refute Cron.matches?(cron, ~N[2026-10-10 08:00:00])
  end

  test "steps and sunday as 7" do
    {:ok, every} = Cron.parse("*/15 * * * *")
    assert Cron.matches?(every, ~N[2026-10-09 10:45:00])
    refute Cron.matches?(every, ~N[2026-10-09 10:50:00])

    {:ok, sunday} = Cron.parse("0 9 * * 7")
    assert Cron.matches?(sunday, ~N[2026-10-11 09:00:00])
  end

  test "next run" do
    {:ok, cron} = Cron.parse("0 8 * * 1-5")
    assert Cron.next(cron, ~N[2026-10-09 09:00:00]) == ~N[2026-10-12 08:00:00]
  end

  test "describes common shapes" do
    assert Cron.describe("0 8 * * 1-5") == "weekdays 08:00"
    assert Cron.describe("*/30 * * * *") == "every 30 min"
    assert Cron.describe("0 15 * * 5") == "Fri 15:00"
    assert Cron.describe("1 2 3 4 5") == "1 2 3 4 5"
  end
end
