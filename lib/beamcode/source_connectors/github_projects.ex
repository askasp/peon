defmodule Beamcode.SourceConnectors.GithubProjects do
  @moduledoc """
  GitHub Projects (v2) as a Dataset source: a project's items become rows of
  `items`, one column per Status/Iteration/text/number/date field. Config:
  `"project": "owner/number"`. Uses the GraphQL API with a token that has the
  `project` scope (and `repo` to comment on or close private issues).
  """
  @behaviour Beamcode.SourceConnector
  import Beamcode.SourceConnector, only: [column: 1]

  @url "https://api.github.com/graphql"
  # Field types that become columns; the rest (title, assignees, labels…) are
  # fixed columns or not synced.
  @field_types ~w(SINGLE_SELECT ITERATION TEXT NUMBER DATE)
  @fixed ~w(number title type state url repo assignees labels)

  @impl true
  def info do
    %{
      id: "github.projects",
      name: "GitHub Projects",
      short: "GH",
      secret: "GITHUB_TOKEN",
      table: "items",
      config_key: "project",
      actions: %{
        "setField" => %{label: "Change fields", default: "direct", needs_row: true},
        "comment" => %{label: "Comment on an issue", default: "confirm", needs_row: true},
        "create" => %{label: "Create a draft issue", default: "confirm", needs_row: false},
        "close" => %{label: "Close an issue", default: "off", needs_row: true}
      }
    }
  end

  @impl true
  def account(token) do
    with {:ok, %{"viewer" => %{"login" => login}}} <- graphql(token, "query{viewer{login}}", %{}),
         do: {:ok, login}
  end

  @impl true
  def choices(token) do
    query = """
    query {
      viewer {
        login
        projectsV2(first: 30) { nodes { number title closed items { totalCount } } }
        organizations(first: 30) {
          nodes { login projectsV2(first: 30) { nodes { number title closed items { totalCount } } } }
        }
      }
    }
    """

    with {:ok, %{"viewer" => v}} <- graphql(token, query, %{}) do
      owners = [
        {v["login"], v["projectsV2"]}
        | for(o <- v["organizations"]["nodes"], do: {o["login"], o["projectsV2"]})
      ]

      {:ok,
       for {owner, %{"nodes" => nodes}} <- owners, p <- nodes, p && !p["closed"] do
         %{
           id: "#{owner}/#{p["number"]}",
           label: p["title"],
           detail: "#{owner} · ##{p["number"]} · #{p["items"]["totalCount"]} items"
         }
       end}
    end
  end

  @impl true
  def pull(token, config) do
    with {:ok, owner, number} <- parse(config["project"]),
         {:ok, project, items} <- fetch_items(token, owner, number, nil, []) do
      fields =
        for f <- project["fields"]["nodes"], f["dataType"] in @field_types do
          col = column(f["name"])
          col = if col in @fixed or String.starts_with?(col, "_"), do: col <> "_field", else: col

          %{
            column: col,
            label: f["name"],
            type: f["dataType"],
            remote_id: f["id"],
            options: options(f)
          }
        end

      by_name = Map.new(fields, &{&1.label, &1.column})

      columns =
        [
          {"number", "integer"},
          {"title", "text"},
          {"type", "text"},
          {"state", "text"},
          {"url", "text"},
          {"repo", "text"},
          {"assignees", "text"},
          {"labels", "text"},
          {"_content_id", "text"}
        ] ++ for(f <- fields, do: {f.column, if(f.type == "NUMBER", do: "real", else: "text")})

      rows =
        for item <- items, !item["isArchived"] do
          c = item["content"] || %{}

          values =
            for v <- item["fieldValues"]["nodes"],
                col = by_name[get_in(v, ["field", "name"])],
                into: %{} do
              {col, v["name"] || v["title"] || v["text"] || v["number"] || v["date"]}
            end

          Map.merge(
            %{
              "_remote_id" => item["id"],
              "number" => c["number"],
              "title" => c["title"],
              "type" => item["type"],
              "state" => c["state"] || if(item["type"] == "DRAFT_ISSUE", do: "DRAFT"),
              "url" => c["url"],
              "repo" => get_in(c, ["repository", "nameWithOwner"]),
              "assignees" => logins(c["assignees"]),
              "labels" => names(c["labels"]),
              "_content_id" => c["id"]
            },
            values
          )
        end

      {:ok,
       %{
         title: project["title"],
         url: project["url"],
         remote_id: project["id"],
         columns: columns,
         rows: rows,
         fields: fields,
         full: true
       }}
    end
  end

  defp parse(spec) when is_binary(spec) do
    case Regex.run(
           ~r{^(?:https://github\.com/(?:orgs/|users/)?)?([\w.-]+)(?:/projects)?/(\d+)/?$},
           String.trim(spec)
         ) do
      [_, owner, n] -> {:ok, owner, String.to_integer(n)}
      _ -> {:error, "GitHub project should look like owner/12"}
    end
  end

  defp parse(_), do: {:error, "GitHub project should look like owner/12"}

  @items """
  query($login: String!, $number: Int!, $after: String) {
    repositoryOwner(login: $login) {
      ... on ProjectV2Owner {
        projectV2(number: $number) {
          id title url
          fields(first: 50) {
            nodes {
              ... on ProjectV2FieldCommon { id name dataType }
              ... on ProjectV2SingleSelectField { options { id name } }
              ... on ProjectV2IterationField {
                configuration {
                  iterations { id title startDate duration }
                  completedIterations { id title startDate duration }
                }
              }
            }
          }
          items(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id type isArchived
              content {
                ... on DraftIssue { id title }
                ... on Issue {
                  id number title state url repository { nameWithOwner }
                  assignees(first: 10) { nodes { login } }
                  labels(first: 10) { nodes { name } }
                }
                ... on PullRequest {
                  id number title state url repository { nameWithOwner }
                  assignees(first: 10) { nodes { login } }
                  labels(first: 10) { nodes { name } }
                }
              }
              fieldValues(first: 40) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
                  ... on ProjectV2ItemFieldIterationValue { title field { ... on ProjectV2FieldCommon { name } } }
                  ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
                  ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
                  ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  # Up to 20 pages (2000 items).
  defp fetch_items(token, owner, number, cursor, acc) do
    case graphql(token, @items, %{login: owner, number: number, after: cursor}) do
      {:ok, %{"repositoryOwner" => %{"projectV2" => %{} = p}}} ->
        acc = acc ++ p["items"]["nodes"]
        page = p["items"]["pageInfo"]

        if page["hasNextPage"] and length(acc) < 2000,
          do: fetch_items(token, owner, number, page["endCursor"], acc),
          else: {:ok, p, acc}

      {:ok, _} ->
        {:error, "No GitHub project #{owner}/#{number}, or the token can't see it"}

      error ->
        error
    end
  end

  defp options(%{"options" => opts}) when is_list(opts),
    do: for(o <- opts, do: %{id: o["id"], name: o["name"]})

  defp options(%{"configuration" => %{} = c}) do
    for i <- (c["completedIterations"] || []) ++ (c["iterations"] || []) do
      %{id: i["id"], name: i["title"], start: i["startDate"], days: i["duration"]}
    end
    |> Enum.sort_by(& &1.start)
  end

  defp options(_), do: []

  defp logins(%{"nodes" => n}), do: n |> Enum.map(& &1["login"]) |> Enum.join(", ")
  defp logins(_), do: nil
  defp names(%{"nodes" => n}), do: n |> Enum.map(& &1["name"]) |> Enum.join(", ")
  defp names(_), do: nil

  ## Actions

  @impl true
  def prepare("setField", %{"field" => col} = args, row, fields) when is_map(row) do
    value = args["value"]

    case Enum.find(fields, &(&1["column"] == col)) do
      nil ->
        {:error,
         "#{col} isn't a GitHub field. Fields: #{Enum.map_join(fields, ", ", & &1["column"])}"}

      f ->
        with {:ok, value} <- field_value(f, value) do
          {:ok, %{col => value}, "#{f["label"]} → #{value || "empty"}"}
        end
    end
  end

  def prepare("setField", _args, _row, _fields), do: {:error, "setField needs field and value"}

  def prepare("comment", %{"body" => body}, row, _fields) when is_binary(body) and body != "" do
    if row["_content_id"] && row["type"] != "DRAFT_ISSUE",
      do: {:ok, %{}, "Comment on #{ref(row)}"},
      else: {:error, "Drafts can't have comments"}
  end

  def prepare("comment", _args, _row, _fields), do: {:error, "comment needs a body"}

  def prepare("create", %{"title" => title}, _row, _fields) when is_binary(title) and title != "",
    do: {:ok, %{}, "Draft: #{title}"}

  def prepare("create", _args, _row, _fields), do: {:error, "create needs a title"}

  def prepare("close", _args, row, _fields) do
    if row["type"] in ["ISSUE", "PULL_REQUEST"],
      do: {:ok, %{"state" => "CLOSED"}, "Close #{ref(row)}"},
      else: {:error, "Only issues and pull requests can be closed"}
  end

  def prepare("reopen", _args, row, _fields) do
    if row["type"] in ["ISSUE", "PULL_REQUEST"],
      do: {:ok, %{"state" => "OPEN"}, "Reopen #{ref(row)}"},
      else: {:error, "Only issues and pull requests can be reopened"}
  end

  def prepare(action, _args, _row, _fields), do: {:error, "GitHub has no action #{action}"}

  defp ref(row), do: if(row["number"], do: "##{row["number"]}", else: row["title"])

  # Option names are matched without case, so "todo" finds "Todo".
  defp field_value(_f, nil), do: {:ok, nil}
  defp field_value(_f, ""), do: {:ok, nil}

  defp field_value(%{"type" => t} = f, value) when t in ["SINGLE_SELECT", "ITERATION"] do
    case find_option(f, value) do
      nil -> {:error, "#{f["label"]} can be #{Enum.map_join(f["options"], ", ", & &1["name"])}"}
      o -> {:ok, o["name"]}
    end
  end

  defp field_value(%{"type" => "NUMBER"} = f, value) do
    case Float.parse(to_string(value)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "#{f["label"]} is a number"}
    end
  end

  defp field_value(%{"type" => "DATE"} = f, value) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, _} -> {:ok, to_string(value)}
      _ -> {:error, "#{f["label"]} is a date like 2026-10-13"}
    end
  end

  defp field_value(_f, value), do: {:ok, to_string(value)}

  defp find_option(f, value) do
    v = String.downcase(to_string(value))
    Enum.find(f["options"] || [], &(String.downcase(&1["name"]) == v or &1["id"] == value))
  end

  @impl true
  def post(token, "setField", %{"field" => col} = args, row, source, fields) do
    f = Enum.find(fields, &(&1["column"] == col))
    ids = %{projectId: source["remote_id"], itemId: row["_remote_id"], fieldId: f["remote_id"]}

    if args["value"] in [nil, ""] do
      mutate(token, "clearProjectV2ItemFieldValue", ids)
    else
      value =
        case f["type"] do
          "SINGLE_SELECT" -> %{singleSelectOptionId: find_option(f, args["value"])["id"]}
          "ITERATION" -> %{iterationId: find_option(f, args["value"])["id"]}
          "NUMBER" -> %{number: elem(Float.parse(to_string(args["value"])), 0)}
          "DATE" -> %{date: args["value"]}
          _ -> %{text: to_string(args["value"])}
        end

      mutate(token, "updateProjectV2ItemFieldValue", Map.put(ids, :value, value))
    end
  end

  def post(token, "comment", %{"body" => body}, row, _source, _fields),
    do: mutate(token, "addComment", %{subjectId: row["_content_id"], body: body})

  def post(token, "create", args, _row, source, _fields) do
    input = %{projectId: source["remote_id"], title: args["title"]}
    input = if is_binary(args["body"]), do: Map.put(input, :body, args["body"]), else: input
    mutate(token, "addProjectV2DraftIssue", input)
  end

  def post(token, action, _args, row, _source, _fields) when action in ["close", "reopen"] do
    {kind, id_key} =
      if row["type"] == "PULL_REQUEST",
        do: {"PullRequest", :pullRequestId},
        else: {"Issue", :issueId}

    mutate(token, "#{action}#{kind}", %{id_key => row["_content_id"]})
  end

  defp mutate(token, name, input) do
    type = String.upcase(String.first(name)) <> String.slice(name, 1..-1//1) <> "Input"

    case graphql(token, "mutation($input: #{type}!){#{name}(input: $input){clientMutationId}}", %{
           input: input
         }) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def undo("setField", %{"field" => col}, before),
    do: {"setField", %{"field" => col, "value" => before[col]}}

  def undo("close", _args, _before), do: {"reopen", %{}}
  def undo("reopen", _args, _before), do: {"close", %{}}
  def undo(_action, _args, _before), do: nil

  ## HTTP

  defp graphql(token, query, variables) do
    req = Beamcode.SourceConnector.req(url: @url, auth: {:bearer, token})

    case Req.post(req, json: %{query: query, variables: variables}) do
      {:ok, %{status: 200, body: %{"errors" => [e | _]}}} -> {:error, "GitHub: #{e["message"]}"}
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      {:ok, %{status: 401}} -> {:error, "GitHub didn't accept the token. Connect again."}
      {:ok, %{status: s, body: b}} -> {:error, "GitHub answered #{s}: #{message(b)}"}
      {:error, e} -> {:error, "GitHub: #{Exception.message(e)}"}
    end
  end

  defp message(%{"message" => m}), do: m
  defp message(b), do: inspect(b) |> String.slice(0, 200)
end
