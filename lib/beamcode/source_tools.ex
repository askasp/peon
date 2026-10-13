defmodule Beamcode.SourceTools do
  @moduledoc """
  The agent's side of a synced Dataset, as gateway MCP tools: `source_act`
  queues a change for the service in the Outbox (the same `act` views call,
  with the same levels), `source_sync` pulls now. The agent reads the rows
  itself with sqlite3 and never calls the service directly.
  """
  alias Beamcode.{DataSources, Outbox}

  def mcp_tools(project) do
    sources = DataSources.connector_sources(project)

    if sources == %{} do
      []
    else
      actions =
        Enum.map_join(sources, "; ", fn {name, s} ->
          levels =
            for {action, _} <- Enum.sort(DataSources.info(s).actions),
                do: "#{action} (#{DataSources.level(s, action)})"

          "#{name} → table #{s.table}: #{Enum.join(levels, ", ")}"
        end)

      [
        %{
          name: "source_act",
          description:
            "Post a change back to a synced source's service through the Outbox. " <>
              "direct actions post at once; confirm actions wait for the user to press Post " <>
              "(tell them it's waiting); off actions are refused. Sources: #{actions}. " <>
              "A table from the Project's API calls: the action is a write call's name, its " <>
              "args are that call's arguments, and the row fills `{id}` and its columns. " <>
              "GitHub Projects and Front sources from before: setField args: {field: column, value}; " <>
              "comment/reply args: {body}; create args: {title, body?}; assign args: {to: email}.",
          inputSchema: %{
            type: "object",
            properties: %{
              action: %{type: "string"},
              row: %{type: "string", description: "The row's _remote_id (empty for create)"},
              args: %{type: "object"},
              source: %{
                type: "string",
                description: "Needed when the Project has more than one source"
              }
            },
            required: ["action"]
          }
        },
        %{
          name: "source_sync",
          description: "Pull a synced source again now (it also syncs every few minutes).",
          inputSchema: %{
            type: "object",
            properties: %{source: %{type: "string"}},
            required: []
          }
        }
      ]
    end
  end

  @doc "`{:ok, text}` or `{:error, text}` for the gateway."
  def call(project, "source_act", args) do
    case Outbox.act(
           project,
           blank(args["source"]),
           to_string(args["action"]),
           blank(args["row"]),
           args["args"],
           "chat"
         ) do
      {:ok, %{"status" => "waiting"} = e} ->
        {:ok, "Waiting in the Outbox for the user to press Post: #{e["label"]}"}

      {:ok, e} ->
        {:ok,
         "Posting: #{e["label"]}. The row shows it at once; it's undone if the service refuses."}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  def call(project, "source_sync", args) do
    names =
      case blank(args["source"]) do
        nil -> project |> DataSources.connector_sources() |> Map.keys()
        name -> [name]
      end

    results =
      for name <- names do
        case DataSources.refresh(project, name) do
          :ok -> "#{name}: synced"
          {:error, reason} -> "#{name}: #{reason}"
        end
      end

    {:ok, Enum.join(results, "\n")}
  end

  defp blank(v) when v in [nil, ""], do: nil
  defp blank(v), do: to_string(v)
end
