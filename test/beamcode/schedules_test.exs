defmodule Beamcode.SchedulesTest do
  use ExUnit.Case, async: true
  alias Beamcode.Schedules

  test "run titles carry the schedule's name" do
    at = ~N[2026-10-09 18:09:00]
    assert Schedules.run_title("morning-digest", at) == "morning-digest · Fri 9 Oct 18:09"
    assert Schedules.run_title("manual", at) == "Run · Fri 9 Oct 18:09"
  end

  describe "summary_line/1" do
    test "a result with run-links counts them, with the total when it can" do
      text = """
      Three customers asked for a refund.

      - **Ola** · 299 NOK [Send refund](run:refund?charge=ch_1&amount=299&currency=NOK)
      - **Kari** · 499 NOK [Send refund](run:refund?charge=ch_2&amount=499&currency=NOK)
      - **Jonas** · 99 NOK [Send refund](run:refund?charge=ch_3&amount=99&currency=NOK)
      """

      assert Schedules.summary_line(text) == "3 × Send refund · 897 NOK"
    end

    test "no total without amounts in one currency" do
      text = "[Fix](run:fix?id=1) [Fix](run:fix?id=2&amount=3&currency=NOK)"
      assert Schedules.summary_line(text) == "2 × Fix"
    end

    test "headings, and the peon-status block left out" do
      text = "## Urgent\n## Waiting\n```peon-status\n{\"key\": \"a\"}\n```"
      assert Schedules.summary_line(text) == "Urgent · Waiting"
      assert Schedules.summary_line("```peon-status\n{}\n```\nRefunded 1.") == "Refunded 1."
    end
  end
end
