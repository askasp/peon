defmodule Beamcode.SessionsTest do
  use ExUnit.Case, async: false

  import Beamcode.OpencodeStub
  alias Beamcode.{Opencode, Sessions}

  describe "slash_items/2" do
    test "asks again while OpenCode is still loading the folder" do
      calls = start_supervised!({Agent, fn -> 0 end})

      setup_stub(fn conn ->
        n = Agent.get_and_update(calls, &{&1, &1 + 1})

        case {conn.request_path, n} do
          # The first skill and command requests answer empty, as OpenCode does.
          {_, n} when n < 2 -> data(conn, [])
          {"/api/skill", _} -> data(conn, [%{"id" => "hello", "description" => "Says hello"}])
          {"/api/command", _} -> data(conn, [%{"name" => "review", "description" => "Review"}])
        end
      end)

      assert Sessions.slash_items("/srv/app") == [
               %{name: "hello", description: "Says hello", kind: "skill"},
               %{name: "review", description: "Review", kind: "command"}
             ]
    end

    test "gives up with an empty list" do
      setup_stub(&data(&1, []))
      assert Sessions.slash_items("/srv/app", 2) == []
    end
  end

  test "find_files/2 searches the folder" do
    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/api/fs/find"
      assert conn.query_params["query"] == "sess"
      assert conn.query_params["location"] == %{"directory" => "/srv/app"}
      data(conn, [%{"path" => "lib/sessions.ex", "type" => "file"}])
    end)

    assert {:ok, [%{"path" => "lib/sessions.ex"}]} = Opencode.find_files("/srv/app", "sess")
  end
end
