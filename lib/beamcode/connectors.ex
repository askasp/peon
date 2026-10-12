defmodule Beamcode.Connectors do
  @moduledoc """
  One generic connector. Reads `setup/connectors/*.json` from the OpenCode
  server and turns each tool into an MCP tool for the projects listed in the
  file. The setup project sees every connector so sessions there can test them.

  See `Beamcode.Workspace` (setup AGENTS.md) for the file format.
  """
  require Logger
  alias Beamcode.{Opencode, Projects, Vault, Workspace}
  alias Beamcode.Projects.Project

  @methods ~w(GET POST PUT PATCH DELETE)
  @permissions ~w(allow ask deny)

  @doc "All connector files, parsed. Each has `:error` set when the file is invalid."
  def list do
    with %Project{directory: dir} <- Workspace.setup_project(),
         {:ok, entries} <- Opencode.list_dir(dir, "connectors") do
      entries
      |> Enum.filter(&(&1["type"] == "file" and String.ends_with?(&1["path"], ".json")))
      |> Enum.map(&Path.basename(&1["path"]))
      |> Enum.sort()
      |> Enum.map(fn file ->
        case Opencode.read_file(dir, "connectors/" <> file) do
          {:ok, body} ->
            parse(file, body)

          {:error, e} ->
            %{name: Path.rootname(file), file: file, error: inspect(e), tools: [], projects: []}
        end
      end)
    else
      _ -> []
    end
  end

  def parse(file, body) do
    base = %{
      name: Path.rootname(file),
      file: file,
      error: nil,
      tools: [],
      projects: [],
      raw: body
    }

    with {:ok, json} when is_map(json) <- Jason.decode(body),
         {:ok, tools} <- parse_tools(json["tools"]) do
      auth = json["auth"] || %{"type" => "none"}

      %{
        base
        | tools: tools,
          projects: List.wrap(json["projects"]) |> Enum.map(&to_string/1)
      }
      |> Map.merge(%{
        base_url: to_string(json["baseUrl"] || ""),
        auth: auth,
        secret: auth["secret"],
        per_minute: get_in(json, ["rateLimit", "perMinute"]),
        compact: json["compact"] == true
      })
    else
      {:ok, _} -> %{base | error: "must be a JSON object"}
      {:error, %Jason.DecodeError{} = e} -> %{base | error: Exception.message(e)}
      {:error, msg} -> %{base | error: msg}
    end
  end

  defp parse_tools(tools) when is_map(tools) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {name, spec}, {:ok, acc} ->
      case parse_tool(name, spec) do
        {:ok, tool} -> {:cont, {:ok, acc ++ [tool]}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_tools(_), do: {:error, "\"tools\" must be an object"}

  defp parse_tool(name, [method, path, perm | rest]) do
    method = String.upcase(to_string(method))

    cond do
      not Regex.match?(~r/^[a-z0-9_]+$/, name) ->
        {:error, "tool #{name}: use lowercase snake_case"}

      method not in @methods ->
        {:error, "tool #{name}: unknown method #{method}"}

      perm not in @permissions ->
        {:error, "tool #{name}: permission must be allow, ask or deny"}

      true ->
        {:ok,
         %{
           name: name,
           method: method,
           path: to_string(path),
           permission: perm,
           description: List.first(rest)
         }}
    end
  end

  defp parse_tool(name, _), do: {:error, "tool #{name}: expected [method, path, permission]"}

  @doc "Connectors a project may use: listed in `projects`, valid and with the secret set."
  def for_project(%Project{} = project, connectors \\ list()) do
    secrets = Vault.names()

    Enum.filter(connectors, fn c ->
      c.error == nil and (project.kind == "system" or project.name in c.projects) and
        ready?(c, secrets)
    end)
  end

  def ready?(c, secrets \\ Vault.names()),
    do: c.error == nil and (c.secret == nil or MapSet.member?(secrets, c.secret))

  def tool_name(connector, tool), do: "#{connector.name}_#{tool.name}"

  @doc "The OpenCode permission action for a gateway MCP tool."
  def permission_action(connector, tool),
    do: "#{Workspace.gateway_server()}_#{tool_name(connector, tool)}"

  def mcp_tools(project) do
    for c <- for_project(project), t <- c.tools, t.permission != "deny" do
      params = Regex.scan(~r/\{(\w+)\}/, t.path) |> Enum.map(&List.last/1)

      %{
        name: tool_name(c, t),
        description: t.description || "#{t.method} #{c.base_url}#{t.path}",
        inputSchema: %{
          type: "object",
          properties:
            Map.new(params, &{&1, %{type: "string"}})
            |> Map.merge(%{
              query: %{type: "object", description: "Query string parameters"},
              body: %{type: "object", description: "JSON request body"}
            }),
          required: params
        }
      }
    end
  end

  def call(project, name, args) do
    found =
      for c <- for_project(project),
          t <- c.tools,
          t.permission != "deny",
          tool_name(c, t) == name do
        {c, t}
      end

    case found do
      [{c, t} | _] -> do_call(c, t, args || %{})
      [] -> {:error, "unknown tool #{name}"}
    end
  end

  defp do_call(c, t, args) do
    params = Regex.scan(~r/\{(\w+)\}/, t.path) |> Enum.map(&List.last/1)
    missing = Enum.filter(params, &(to_string(args[&1] || "") |> String.trim() == ""))

    # Each value is one path segment: escape "/", "?", "#" and spaces in it.
    path =
      Regex.replace(~r/\{(\w+)\}/, t.path, fn _, key ->
        URI.encode(to_string(args[key]), &URI.char_unreserved?/1)
      end)

    with :ok <-
           if(missing == [],
             do: :ok,
             else: {:error, "#{Enum.join(missing, ", ")} is required and can't be empty"}
           ),
         {:ok, auth} <- auth_options(c.auth) do
      opts =
        [
          method: String.downcase(t.method) |> String.to_existing_atom(),
          url: c.base_url <> path,
          retry: false,
          receive_timeout: 60_000,
          decode_body: false
        ]
        |> Keyword.merge(auth, fn
          :params, a, b -> a ++ b
          _, _, b -> b
        end)
        |> add_params(args["query"])
        |> then(fn o ->
          if is_map(args["body"]), do: Keyword.put(o, :json, args["body"]), else: o
        end)
        |> add_headers(args["headers"])

      case request_with_retry(c, opts, 3) do
        {:ok, %Req.Response{status: status, body: body}} ->
          body = if c[:compact], do: compact(to_string(body)), else: to_string(body)
          {:ok, status, truncate(body)}

        {:error, e} ->
          {:error, Exception.message(e)}
      end
    end
  end

  # Extra headers a procedure's call step sends (an Idempotency-Key).
  defp add_headers(opts, headers) when is_map(headers) and map_size(headers) > 0 do
    extra = for {k, v} <- headers, is_binary(k), do: {k, to_string(v)}
    Keyword.update(opts, :headers, extra, &(List.wrap(&1) ++ extra))
  end

  defp add_headers(opts, _), do: opts

  # Paces calls per connector, and on 429 waits as long as the API asks
  # (Retry-After, or "retry in N milliseconds" in the body), then tries again.
  defp request_with_retry(c, opts, attempts) do
    Beamcode.Connectors.Limiter.acquire(c.name, c[:per_minute])

    case Req.request(opts) do
      {:ok, %Req.Response{status: 429} = resp} when attempts > 1 ->
        Process.sleep(retry_after_ms(resp))
        request_with_retry(c, opts, attempts - 1)

      other ->
        other
    end
  end

  @max_wait 30_000
  @doc false
  def retry_after_ms(%Req.Response{} = resp) do
    header = resp |> Req.Response.get_header("retry-after") |> List.first()

    ms =
      cond do
        header && match?({_, ""}, Integer.parse(header)) ->
          elem(Integer.parse(header), 0) * 1000

        m = Regex.run(~r/retry in (\d+) ?ms|retry in (\d+) milliseconds/i, to_string(resp.body)) ->
          m |> Enum.drop(1) |> Enum.find(&(&1 != "")) |> String.to_integer()

        true ->
          10_000
      end

    min(ms + 250, @max_wait)
  end

  @doc """
  Slims a JSON response for the model: drops `_links` everywhere, and an HTML
  `body` where a plain `text` copy sits next to it. Non-JSON is left alone.
  """
  def compact(body) do
    case Jason.decode(body) do
      {:ok, json} -> Jason.encode!(slim(json))
      _ -> body
    end
  end

  defp slim(%{} = map) do
    map = Map.delete(map, "_links")

    map =
      if is_binary(map["text"]) and is_binary(map["body"]), do: Map.delete(map, "body"), else: map

    Map.new(map, fn {k, v} -> {k, slim(v)} end)
  end

  defp slim(list) when is_list(list), do: Enum.map(list, &slim/1)
  defp slim(other), do: other

  defp add_params(opts, query) when is_map(query) and map_size(query) > 0,
    do: Keyword.update(opts, :params, Map.to_list(query), &(&1 ++ Map.to_list(query)))

  defp add_params(opts, _), do: opts

  defp auth_options(%{"type" => "none"}), do: {:ok, []}

  defp auth_options(%{"type" => type, "secret" => name} = auth) do
    case Vault.fetch(name) do
      {:ok, secret} ->
        case type do
          "bearer" -> {:ok, [auth: {:bearer, secret}]}
          "basic" -> {:ok, [auth: {:basic, secret}]}
          "header" -> {:ok, [headers: [{auth["header"] || "x-api-key", secret}]]}
          "query" -> {:ok, [params: [{auth["param"] || "api_key", secret}]]}
          other -> {:error, "unknown auth type #{other}"}
        end

      :error ->
        {:error, "secret #{name} is not set. Set it on the Connectors page."}
    end
  end

  defp auth_options(_), do: {:ok, []}

  # Keep results readable for the model and always valid UTF-8 (a cut can land
  # inside a multi-byte character like "ø").
  @max_body 60_000
  def truncate(body) do
    body = String.replace_invalid(body, "")

    if byte_size(body) > @max_body do
      String.replace_invalid(binary_part(body, 0, @max_body), "") <>
        "\n…(truncated at #{div(@max_body, 1000)} KB; narrow the query or use pagination)"
    else
      body
    end
  end

  @doc """
  Writes the gateway server and per-tool permissions into every routine, chat
  and system project's opencode.json. Cheap when nothing changed.
  """
  def sync_all do
    connectors = list()

    Projects.list_projects()
    |> Enum.filter(&Workspace.uses_gateway?/1)
    |> Enum.each(fn project ->
      rules =
        for c <- for_project(project, connectors), t <- c.tools, t.permission != "deny" do
          %{"action" => permission_action(c, t), "resource" => "*", "effect" => t.permission}
        end

      case Workspace.sync_opencode_json(project, rules) do
        :ok -> :ok
        error -> Logger.warning("opencode.json sync for #{project.name}: #{inspect(error)}")
      end
    end)
  end

  @doc "Adds or removes a project from a connector file's `projects` list."
  def set_granted(connector_name, project_name, granted?) do
    with %Project{directory: dir} <- Workspace.setup_project(),
         path = "connectors/#{connector_name}.json",
         {:ok, body} <- Opencode.read_file(dir, path),
         {:ok, json} when is_map(json) <- Jason.decode(body) do
      projects = List.wrap(json["projects"]) -- [project_name]
      projects = if granted?, do: projects ++ [project_name], else: projects

      Opencode.write_file(
        dir,
        path,
        Jason.encode!(Map.put(json, "projects", projects), pretty: true) <> "\n"
      )
    end
  end
end
