defmodule Beamcode.RoutinesTest do
  use ExUnit.Case, async: true
  alias Beamcode.Routines

  @config %{
    run: "/digest since {since} in {inboxes}",
    inputs: [
      %{
        name: "inboxes",
        default: ["Support", "Billing"],
        options: ["Support", "Billing", "Sales"],
        multi: true
      },
      %{name: "since", default: "last run", options: ["last run", "today"], multi: false}
    ],
    error: nil
  }

  test "fills placeholders with defaults" do
    assert Routines.prompt(@config, %{}) == "/digest since last run in Support, Billing"
  end

  test "given values win, lists are joined" do
    assert Routines.prompt(@config, %{"since" => "today", "inboxes" => ["Sales"]}) ==
             "/digest since today in Sales"
  end

  test "unknown placeholders are left alone" do
    assert Routines.prompt(%{@config | run: "/x {nope}"}, %{}) == "/x {nope}"
  end
end
