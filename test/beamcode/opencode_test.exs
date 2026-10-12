defmodule Beamcode.OpencodeTest do
  use ExUnit.Case, async: false

  import Beamcode.OpencodeStub
  alias Beamcode.Opencode

  test "agents waits out a folder OpenCode is still loading" do
    calls = start_supervised!({Agent, fn -> 0 end})

    setup_stub(fn conn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> data(conn, [])
        _ -> data(conn, [%{"id" => "build"}, %{"id" => "plan"}])
      end
    end)

    assert {:ok, [%{"id" => "build"}, %{"id" => "plan"}]} = Opencode.agents("/srv/app")
    assert Agent.get(calls, & &1) == 2
  end

  test "agents gives up and returns the empty list after a few tries" do
    setup_stub(&data(&1, []))
    assert {:ok, []} = Opencode.agents("/srv/app", 2)
  end
end
