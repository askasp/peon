defmodule BeamcodeWeb.McpController do
  @moduledoc """
  Minimal MCP server (streamable HTTP, JSON responses) that exposes connector
  tools, and a synced Dataset's `source_act`/`source_sync` (`Beamcode.SourceTools`). The URL carries a signed project id, written into the project's
  opencode.json by `Beamcode.Workspace.sync_opencode_json/2`.
  """
  use BeamcodeWeb, :controller
  alias Beamcode.{Connectors, Projects, SourceTools}

  @protocol "2025-06-18"

  def handle(conn, %{"token" => token} = params) do
    with {:ok, project_id} <- Beamcode.Workspace.verify_mcp_token(token),
         %{} = project <- Projects.get_project(project_id) do
      case Map.drop(params, ["token"]) do
        %{"_json" => batch} when is_list(batch) ->
          replies = batch |> Enum.map(&rpc(project, &1)) |> Enum.reject(&is_nil/1)
          reply(conn, replies)

        message ->
          reply(conn, rpc(project, message))
      end
    else
      _ -> conn |> put_status(401) |> json(%{error: "invalid token"})
    end
  end

  def not_allowed(conn, _params), do: conn |> put_status(405) |> text("")

  defp reply(conn, nil), do: send_resp(conn, 202, "")
  defp reply(conn, []), do: send_resp(conn, 202, "")
  defp reply(conn, body), do: json(conn, body)

  defp rpc(_project, %{"method" => "notifications/" <> _}), do: nil

  defp rpc(_project, %{"id" => id, "method" => "initialize"} = msg) do
    ok(id, %{
      protocolVersion: get_in(msg, ["params", "protocolVersion"]) || @protocol,
      capabilities: %{tools: %{listChanged: false}},
      serverInfo: %{name: "peon-gateway", version: "0.1.0"}
    })
  end

  defp rpc(_project, %{"id" => id, "method" => "ping"}), do: ok(id, %{})

  # The agent may have just written an API call file: its permissions go
  # into opencode.json before it sees the tools.
  defp rpc(project, %{"id" => id, "method" => "tools/list"}) do
    Connectors.sync_project(project)
    ok(id, %{tools: Connectors.mcp_tools(project) ++ SourceTools.mcp_tools(project)})
  end

  defp rpc(project, %{
         "id" => id,
         "method" => "tools/call",
         "params" => %{"name" => name} = params
       })
       when name in ["source_act", "source_sync"] do
    {result, text} =
      case SourceTools.call(project, name, params["arguments"] || %{}) do
        {:ok, text} -> {false, text}
        {:error, text} -> {true, text}
      end

    ok(id, %{content: [%{type: "text", text: text}], isError: result})
  end

  defp rpc(project, %{"id" => id, "method" => "tools/call", "params" => params}) do
    result =
      with :ok <- Connectors.gateway_ready?(project, params["name"]),
           do: Connectors.call(project, params["name"], params["arguments"])

    case result do
      {:ok, status, body} ->
        ok(id, %{
          content: [%{type: "text", text: "HTTP #{status}\n#{body}"}],
          isError: status >= 400
        })

      {:error, msg} ->
        ok(id, %{content: [%{type: "text", text: msg}], isError: true})
    end
  end

  defp rpc(_project, %{"id" => id, "method" => method}),
    do: %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "method not found: #{method}"}}

  defp rpc(_project, _), do: nil

  defp ok(id, result), do: %{jsonrpc: "2.0", id: id, result: result}
end
