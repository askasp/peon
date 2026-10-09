defmodule BeamcodeWeb.McpControllerTest do
  use BeamcodeWeb.ConnCase, async: true
  alias Beamcode.{Projects, Workspace}

  setup do
    {:ok, project} =
      Projects.insert_project(
        %{name: "r", kind: "routine", directory: "/srv/routines/r", scope: "team"},
        nil
      )

    %{token: Workspace.mcp_token(project.id)}
  end

  test "rejects a bad token", %{conn: conn} do
    conn =
      post(conn, "/mcp/1.nottherightmac", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    assert conn.status == 401
  end

  test "token is stable", %{token: token} do
    [id, _] = String.split(token, ".")
    assert Workspace.mcp_token(String.to_integer(id)) == token
  end

  test "initialize, ping and notifications", %{conn: conn, token: token} do
    resp =
      conn
      |> post("/mcp/#{token}", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      })
      |> json_response(200)

    assert resp["result"]["serverInfo"]["name"] == "peon-gateway"
    assert resp["result"]["capabilities"]["tools"]

    conn2 =
      post(build_conn(), "/mcp/#{token}", %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    assert conn2.status == 202
  end

  test "unknown methods are JSON-RPC errors", %{conn: conn, token: token} do
    resp =
      conn
      |> post("/mcp/#{token}", %{"jsonrpc" => "2.0", "id" => 7, "method" => "nope"})
      |> json_response(200)

    assert resp["error"]["code"] == -32601
  end
end
