defmodule Beamcode.SourceConnectors.Front do
  @moduledoc """
  Front as a Dataset source: an inbox's latest conversations become rows of
  `conversations`, with the last message's text. Config: `"inbox": "inb_…"`
  (all conversations the token sees when empty). Replies, archive and assign
  post back through Front's API (an API token from Settings → Developers).
  """
  @behaviour Beamcode.SourceConnector
  import Beamcode.SourceConnector, only: [iso: 1]

  @url "https://api2.frontapp.com"
  # Conversations per sync (the newest first); older rows stay as they were.
  @pages 3
  @per_minute 50

  @impl true
  def info do
    %{
      id: "front",
      name: "Front",
      short: "F",
      secret: "FRONT_TOKEN",
      table: "conversations",
      config_key: "inbox",
      actions: %{
        "archive" => %{label: "Archive a conversation", default: "direct", needs_row: true},
        "reopen" => %{label: "Reopen a conversation", default: "direct", needs_row: true},
        "assign" => %{label: "Assign a conversation", default: "direct", needs_row: true},
        "reply" => %{label: "Reply", default: "confirm", needs_row: true}
      }
    }
  end

  @impl true
  def account(token) do
    with {:ok, me} <- get(token, "/me"), do: {:ok, me["name"] || me["id"] || "Front"}
  end

  @impl true
  def choices(token) do
    with {:ok, %{"_results" => inboxes}} <- get(token, "/inboxes") do
      {:ok,
       [%{id: "", label: "All conversations", detail: "Every inbox the token sees"}] ++
         for(i <- inboxes, do: %{id: i["id"], label: i["name"], detail: "Inbox"})}
    end
  end

  @impl true
  def pull(token, config) do
    path =
      case config["inbox"] do
        id when is_binary(id) and id != "" -> "/inboxes/#{URI.encode(id)}/conversations"
        _ -> "/conversations"
      end

    with {:ok, convs} <- pages(token, path <> "?limit=100", @pages, []),
         {:ok, team} <- get(token, "/teammates"),
         title = title(token, config["inbox"]) do
      rows =
        for c <- convs do
          last = c["last_message"] || %{}

          %{
            "_remote_id" => c["id"],
            "subject" => c["subject"],
            "status" => c["status"],
            "assignee" => get_in(c, ["assignee", "email"]),
            "contact" => get_in(c, ["recipient", "name"]) || get_in(c, ["recipient", "handle"]),
            "contact_handle" => get_in(c, ["recipient", "handle"]),
            "tags" => (c["tags"] || []) |> Enum.map(& &1["name"]) |> Enum.join(", "),
            "last_message" => last["text"] || last["blurb"],
            "last_message_from" => author(last),
            "last_message_inbound" => if(last["is_inbound"], do: 1, else: 0),
            "last_message_at" => iso(last["created_at"]),
            "created_at" => iso(c["created_at"]),
            "url" => "https://app.frontapp.com/open/#{c["id"]}"
          }
        end

      teammates = for t <- team["_results"] || [], do: %{id: t["id"], name: t["email"]}

      {:ok,
       %{
         title: title,
         url: nil,
         remote_id: config["inbox"],
         columns: [
           {"subject", "text"},
           {"status", "text"},
           {"assignee", "text"},
           {"contact", "text"},
           {"contact_handle", "text"},
           {"tags", "text"},
           {"last_message", "text"},
           {"last_message_from", "text"},
           {"last_message_inbound", "integer"},
           {"last_message_at", "text"},
           {"created_at", "text"},
           {"url", "text"}
         ],
         rows: rows,
         fields: [
           %{
             column: "status",
             label: "Status",
             type: "STATUS",
             remote_id: nil,
             options: for(s <- ~w(unassigned assigned archived), do: %{id: s, name: s})
           },
           %{
             column: "assignee",
             label: "Assignee",
             type: "TEAMMATE",
             remote_id: nil,
             options: teammates
           }
         ],
         full: false
       }}
    end
  end

  defp title(_token, inbox) when inbox in [nil, ""], do: "All conversations"

  defp title(token, inbox) do
    case get(token, "/inboxes/#{URI.encode(inbox)}") do
      {:ok, %{"name" => name}} -> name
      _ -> inbox
    end
  end

  defp author(%{"author" => %{"email" => e}}) when is_binary(e), do: e

  defp author(%{"recipients" => rs}) when is_list(rs) do
    case Enum.find(rs, &(&1["role"] == "from")) do
      %{"name" => n} when is_binary(n) -> n
      %{"handle" => h} -> h
      _ -> nil
    end
  end

  defp author(_), do: nil

  defp pages(_token, nil, _left, acc), do: {:ok, acc}
  defp pages(_token, _path, 0, acc), do: {:ok, acc}

  defp pages(token, path, left, acc) do
    with {:ok, body} <- get(token, path) do
      pages(
        token,
        get_in(body, ["_pagination", "next"]),
        left - 1,
        acc ++ (body["_results"] || [])
      )
    end
  end

  ## Actions

  @impl true
  def prepare("archive", _args, row, _fields),
    do: {:ok, %{"status" => "archived"}, "Archive “#{row["subject"]}”"}

  def prepare("reopen", _args, row, _fields) do
    status = if row["assignee"], do: "assigned", else: "unassigned"
    {:ok, %{"status" => status}, "Reopen “#{row["subject"]}”"}
  end

  def prepare("assign", args, row, fields) do
    to = args["to"]
    team = Enum.find(fields, &(&1["column"] == "assignee"))["options"] || []

    cond do
      to in [nil, ""] ->
        {:ok, %{"assignee" => nil}, "Unassign “#{row["subject"]}”"}

      Enum.any?(team, &(String.downcase(&1["name"]) == String.downcase(to))) ->
        {:ok, %{"assignee" => to}, "Assign “#{row["subject"]}” to #{to}"}

      true ->
        {:error, "#{to} isn't a teammate. Teammates: #{Enum.map_join(team, ", ", & &1["name"])}"}
    end
  end

  def prepare("reply", %{"body" => body}, row, _fields) when is_binary(body) and body != "",
    do: {:ok, %{}, "Reply to #{row["contact"] || row["subject"]}"}

  def prepare("reply", _args, _row, _fields), do: {:error, "reply needs a body"}
  def prepare(action, _args, _row, _fields), do: {:error, "Front has no action #{action}"}

  @impl true
  def post(token, "archive", _args, row, _source, _fields),
    do: write(token, :patch, conv(row), %{status: "archived"})

  def post(token, "reopen", _args, row, _source, _fields),
    do: write(token, :patch, conv(row), %{status: "open"})

  def post(token, "assign", args, row, _source, _fields) do
    id = if args["to"] in [nil, ""], do: nil, else: "alt:email:#{args["to"]}"
    write(token, :put, conv(row) <> "/assignee", %{assignee_id: id})
  end

  def post(token, "reply", %{"body" => body} = args, row, _source, _fields) do
    msg = %{body: body}

    msg =
      if is_binary(args["author"]),
        do: Map.put(msg, :author_id, "alt:email:#{args["author"]}"),
        else: msg

    write(token, :post, conv(row) <> "/messages", msg)
  end

  defp conv(row), do: "/conversations/#{URI.encode(row["_remote_id"])}"

  @impl true
  def undo("archive", _args, _before), do: {"reopen", %{}}
  def undo("reopen", _args, _before), do: {"archive", %{}}
  def undo("assign", _args, before), do: {"assign", %{"to" => before["assignee"]}}
  def undo(_action, _args, _before), do: nil

  ## HTTP

  defp get(token, path), do: request(token, method: :get, url: path)

  defp write(token, method, path, body) do
    case request(token, method: method, url: path, json: body) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp request(token, opts) do
    Beamcode.Connectors.Limiter.acquire("front-source", @per_minute)
    req = Beamcode.SourceConnector.req(base_url: @url, auth: {:bearer, token})

    case Req.request(req, opts) do
      {:ok, %{status: s, body: body}} when s in 200..299 ->
        {:ok, if(is_map(body), do: body, else: %{})}

      {:ok, %{status: 401}} ->
        {:error, "Front didn't accept the token. Connect again."}

      {:ok, %{status: s, body: %{"_error" => %{"message" => m}}}} ->
        {:error, "Front answered #{s}: #{m}"}

      {:ok, %{status: s}} ->
        {:error, "Front answered #{s}"}

      {:error, e} ->
        {:error, "Front: #{Exception.message(e)}"}
    end
  end
end
