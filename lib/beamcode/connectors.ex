defmodule Beamcode.Connectors do
  @moduledoc """
  API calls ("connectors" inside). A Project's own live in
  `.peon/api/<service>.json`, one file per service with its calls; each call
  becomes an MCP tool for that Project, a `call:` step for its procedures, and
  a request a person can send from the app.

  Older shared files, `setup/connectors/*.json`, still reach the projects
  listed in their `projects` until a Project moves one in (`move_here/2`).
  The setup project sees every shared one so sessions there can test them.

  See `format_doc/0` for the file format.
  """
  require Logger
  alias Beamcode.{Opencode, Projects, Sessions, Vault, Workspace}
  alias Beamcode.Procedures.Cache
  alias Beamcode.Projects.Project

  @api_dir ".peon/api"
  def api_dir, do: @api_dir

  @methods ~w(GET POST PUT PATCH DELETE)
  @permissions ~w(allow ask deny)

  @doc "The shared connector files, parsed. Each has `:error` set when the file is invalid."
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
      tables: [],
      raw: body
    }

    with {:ok, json} when is_map(json) <- Jason.decode(body),
         {:ok, tools} <- parse_tools(json["tools"]),
         {:ok, tables} <- parse_tables(json["tables"], tools) do
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
        compact: json["compact"] == true,
        tables: tables
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
           description: List.first(rest),
           body: nil,
           kind: if(method == "GET", do: "read", else: "write"),
           patch: %{}
         }}
    end
  end

  # The longer form, for a call with a fixed body (GraphQL) or one that isn't
  # what its method says (a POST that only reads).
  defp parse_tool(name, %{"method" => method, "path" => path} = spec) do
    with {:ok, tool} <- parse_tool(name, [method, path, spec["permission"] || "allow"]) do
      cond do
        spec["kind"] not in [nil, "read", "write"] ->
          {:error, "tool #{name}: kind must be read or write"}

        not (is_nil(spec["patch"]) or is_map(spec["patch"])) ->
          {:error, "tool #{name}: patch must be an object of column => value"}

        true ->
          {:ok,
           %{
             tool
             | description: spec["description"],
               body: spec["body"],
               kind: spec["kind"] || tool.kind,
               patch: spec["patch"] || %{}
           }}
      end
    end
  end

  defp parse_tool(name, _),
    do: {:error, "tool #{name}: expected [method, path, permission] or {method, path, …}"}

  # "tables": what read calls fill in a Dataset (see Beamcode.ApiTables).
  defp parse_tables(nil, _tools), do: {:ok, []}

  defp parse_tables(tables, tools) when is_map(tables) do
    names = MapSet.new(tools, & &1.name)

    tables
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {name, spec}, {:ok, acc} ->
      cond do
        not Regex.match?(~r/^[a-z][a-z0-9_]{0,40}$/, name) ->
          {:halt, {:error, "table #{name}: use lowercase snake_case"}}

        not is_map(spec) ->
          {:halt, {:error, "table #{name}: expected an object"}}

        not MapSet.member?(names, spec["call"]) ->
          {:halt, {:error, "table #{name}: \"call\" must name one of this file's tools"}}

        not is_map(spec["columns"]) or spec["columns"] == %{} ->
          {:halt, {:error, "table #{name}: \"columns\" maps each column to a path in a row"}}

        bad = Enum.find(Map.keys(spec["columns"]), &(not Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1))) ->
          {:halt, {:error, "table #{name}: column #{bad}: use lowercase snake_case"}}

        true ->
          {:cont, {:ok, acc ++ [Map.put(spec, "name", name)]}}
      end
    end)
  end

  defp parse_tables(_, _), do: {:error, "\"tables\" must be an object"}

  @doc """
  A Project's own services, `.peon/api/*.json`, parsed and with `source:
  "project"` (kept a few seconds, like procedures).
  """
  def local(%Project{directory: dir}),
    do: Cache.fetch({:api_calls, dir}, fn -> read_local(dir) end)

  @doc "Forgets a Project's cached API calls, after a file changed."
  def changed(%Project{directory: dir}), do: Cache.drop({:api_calls, dir})

  defp read_local(dir) do
    case Opencode.list_dir(dir, @api_dir) do
      {:ok, entries} when is_list(entries) ->
        entries
        |> Enum.filter(&(&1["type"] == "file" and String.ends_with?(&1["path"] || "", ".json")))
        |> Enum.map(&Path.basename(&1["path"]))
        |> Enum.sort()
        |> Task.async_stream(
          fn file ->
            case Opencode.read_file(dir, Path.join(@api_dir, file)) do
              {:ok, body} ->
                parse(file, body)

              {:error, e} ->
                %{
                  name: Path.rootname(file),
                  file: file,
                  error: inspect(e),
                  tools: [],
                  projects: []
                }
            end
          end,
          timeout: 30_000,
          max_concurrency: 8
        )
        |> Enum.flat_map(fn
          {:ok, c} -> [Map.merge(c, %{source: "project", path: Path.join(@api_dir, c.file)})]
          _ -> []
        end)

      _ ->
        []
    end
  end

  @doc """
  Every service a Project has, valid or not: its own files, then the shared
  ones listed for it (`source: "shared"`) that no file of its own replaces.
  """
  def all_for(%Project{} = project, shared \\ list()) do
    own = local(project)
    names = MapSet.new(own, & &1.name)

    shared =
      for c <- shared,
          c.error == nil,
          project.kind == "system" or project.name in c.projects,
          not MapSet.member?(names, c.name),
          do: Map.merge(c, %{source: "shared", path: "connectors/" <> c.file})

    own ++ shared
  end

  @doc "The services a Project may call now: valid, and with their secret set in it."
  def for_project(%Project{} = project, shared \\ list()) do
    secrets = Vault.names(project)
    Enum.filter(all_for(project, shared), &ready?(&1, secrets))
  end

  @doc "One of a Project's services by name, ready or not."
  def find(%Project{} = project, name), do: Enum.find(all_for(project), &(&1.name == name))

  def find_tool(c, name) do
    Enum.find(c.tools, &(&1.name == name)) ||
      Enum.find(c.tools, &(&1.name == String.replace(name, ".", "_")))
  end

  @doc "The `{placeholders}` a call's path needs."
  def path_params(tool), do: Regex.scan(~r/\{(\w+)\}/, tool.path) |> Enum.map(&List.last/1)

  @doc """
  Sends one call by hand, whatever its permission (a person asked for it).
  `args` are the path values plus `query` and `body`. Returns `{:ok, %{status,
  body, ms, url}}`.
  """
  def try_call(%Project{} = project, service, call, args) do
    with %{} = c <- find(project, service) || {:error, "No #{service} API."},
         nil <- c.error && {:error, c.error},
         %{} = t <- find_tool(c, call) || {:error, "#{service} has no #{call}."} do
      started = System.monotonic_time(:millisecond)

      case run(project, c, t, args || %{}) do
        {:ok, status, body} ->
          {:ok,
           %{
             status: status,
             body: body,
             ms: System.monotonic_time(:millisecond) - started,
             url: url(c, t, args || %{})
           }}

        error ->
          error
      end
    end
  end

  defp url(c, t, args) do
    path =
      Regex.replace(~r/\{(\w+)\}/, t.path, fn _, key ->
        URI.encode(to_string(args[key]), &URI.char_unreserved?/1)
      end)

    query =
      if is_map(args["query"]) and args["query"] != %{},
        do: "?" <> URI.encode_query(args["query"]),
        else: ""

    c.base_url <> path <> query
  end

  @doc """
  Writes a Project's service file after checking it parses. `name` is the
  service (the file name without `.json`).
  """
  def save(%Project{} = project, name, content) when is_binary(name) and is_binary(content) do
    file = name <> ".json"

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9_-]{0,40}$/, name) ->
        {:error, "Name it in lowercase letters, digits, - or _."}

      (parsed = parse(file, content)).error != nil ->
        {:error, parsed.error}

      true ->
        with {:ok, _} <-
               Opencode.write_file(project.directory, Path.join(@api_dir, file), content) do
          changed(project)
          sync_project(project)
          :ok
        end
    end
  end

  @doc "Removes a Project's service file."
  def delete(%Project{} = project, name) when is_binary(name) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9_-]{0,40}$/, name) do
      with {:ok, 0, _} <-
             Opencode.run_shell(project.directory, "rm -f #{@api_dir}/#{name}.json", 30_000) do
        changed(project)
        sync_project(project)
        :ok
      else
        {:ok, _, out} -> {:error, String.trim(out)}
        error -> error
      end
    else
      {:error, "No such API."}
    end
  end

  @doc """
  Moves a shared connector into the Project: writes it as its own file
  (without `projects`) and takes the Project off the shared file's list.
  """
  def move_here(%Project{} = project, name) do
    with %{source: "shared", raw: raw} <- find(project, name) || {:error, "No shared #{name}."},
         {:ok, json} when is_map(json) <- Jason.decode(raw),
         :ok <-
           save(project, name, Jason.encode!(Map.delete(json, "projects"), pretty: true) <> "\n") do
      if project.kind != "system", do: set_granted(name, project.name, false)
      changed(project)
      sync_project(project)
      :ok
    else
      %{} -> {:error, "#{name} is already this Project's."}
      {:ok, _} -> {:error, "#{name}.json isn't a JSON object."}
      error -> error
    end
  end

  @doc "Whether service `c` is valid and `secrets` (a Project's secret names) has its key."
  def ready?(c, secrets),
    do: c.error == nil and (c.secret == nil or MapSet.member?(secrets, c.secret))

  def tool_name(connector, tool), do: "#{connector.name}_#{tool.name}"

  @doc "The OpenCode permission action for a gateway MCP tool."
  def permission_action(connector, tool),
    do: "#{Workspace.gateway_server()}_#{tool_name(connector, tool)}"

  def mcp_tools(project) do
    for c <- for_project(project), t <- c.tools, t.permission != "deny" do
      params = path_params(t)
      fills = body_params(t) -- params

      body =
        if t.body,
          do:
            "JSON request body; leave it out to send the call's own body filled from the other arguments",
          else: "JSON request body"

      %{
        name: tool_name(c, t),
        description: t.description || "#{t.method} #{c.base_url}#{t.path}",
        inputSchema: %{
          type: "object",
          properties:
            Map.new(params, &{&1, %{type: "string"}})
            |> Map.merge(Map.new(fills, &{&1, %{description: "Goes into the request body"}}))
            |> Map.merge(%{
              query: %{type: "object", description: "Query string parameters"},
              body: %{type: "object", description: body}
            }),
          required: params
        }
      }
    end
  end

  @doc """
  The gateway's `ask_token` tool: the agent asks for a service's token and
  the person sees a card in the chat (drawn from the call's input) that saves
  it to the Project's secrets. The token never passes through the chat.
  """
  def token_tool do
    %{
      name: "ask_token",
      description:
        "Ask the user for an API token. They see a card in the chat to paste it into; it's saved " <>
          "encrypted in this Project only and the gateway calls with it, but you never see it. " <>
          "Never ask for a token in a message. Call it once per token the API file's auth.secret names, " <>
          "then stop and wait: a message tells you when it's saved.",
      inputSchema: %{
        type: "object",
        properties: %{
          name: %{
            type: "string",
            description: "The secret's name, as in auth.secret (UPPER_SNAKE_CASE)"
          },
          service: %{type: "string", description: "The API it's for, e.g. github"},
          what: %{
            type: "string",
            description:
              "What kind of token and which scopes or permissions it needs, in a line, e.g. " <>
                "\"Fine-grained personal access token · Projects: read and write · Issues: write\""
          },
          link: %{type: "string", description: "The page where the user makes one"}
        },
        required: ["name", "service"]
      }
    }
  end

  @doc "Answers the agent's `ask_token` call (the card itself is the call)."
  def ask_token(%Project{} = project, args) do
    name = to_string(args["name"] || "")

    cond do
      not Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, name) ->
        {:error, "name must be UPPER_SNAKE_CASE, as in the API file's auth.secret"}

      MapSet.member?(Vault.names(project), name) ->
        {:ok,
         "#{name} is already set in #{project.name}. Call the API; to replace it, the user uses the API calls tab."}

      true ->
        {:ok,
         "The user sees a card asking for #{name}. It saves to #{project.name}'s secrets, never to the chat. " <>
           "Stop here and wait: you'll get a message when it's saved."}
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
      [{c, t} | _] -> run(project, c, t, args || %{})
      [] -> {:error, "unknown tool #{name}"}
    end
  end

  @doc """
  Whether the agent may send gateway tool `name` now. OpenCode asks a person
  first for an `ask` call only once opencode.json has its rule; a file the
  agent just wrote doesn't, so this writes the rules and refuses the call:
  the next try waits for a person.
  """
  def gateway_ready?(project, name) do
    asks =
      Enum.any?(for_project(project), fn c ->
        Enum.any?(c.tools, &(&1.permission == "ask" and tool_name(c, &1) == name))
      end)

    if asks and not Workspace.asks?(project, "#{Workspace.gateway_server()}_#{name}") do
      sync_project(project)

      {:error,
       "#{name} needs a person's approval, which was only just set up. Call it again: they'll be asked first."}
    else
      :ok
    end
  end

  @doc """
  Sends call `t` of service `c` with the Project's secret. Returns `{:ok,
  status, body}` (slimmed and cut for the model) or `{:error, message}`.
  """
  def run(%Project{} = project, c, t, args) do
    with {:ok, status, body} <- request(project, c, t, args) do
      body = if c[:compact], do: compact(body), else: body
      {:ok, status, truncate(body)}
    end
  end

  @doc """
  Sends call `t` and returns the whole body as it came: `{:ok, status, body}`.
  A call with a `body` template and no `body` argument sends the template
  filled from `args` (see `fill/2`).
  """
  def request(%Project{} = project, c, t, args) do
    params = path_params(t)
    missing = Enum.filter(params, &(to_string(args[&1] || "") |> String.trim() == ""))

    # Each value is one path segment: escape "/", "?", "#" and spaces in it.
    path =
      Regex.replace(~r/\{(\w+)\}/, t.path, fn _, key ->
        URI.encode(to_string(args[key]), &URI.char_unreserved?/1)
      end)

    body =
      cond do
        is_map(args["body"]) -> args["body"]
        t[:body] != nil -> fill(t.body, args)
        true -> nil
      end

    if missing == [] do
      [method: String.downcase(t.method) |> String.to_existing_atom(), url: c.base_url <> path]
      |> add_params(args["query"])
      |> then(fn o -> if body != nil, do: Keyword.put(o, :json, body), else: o end)
      |> add_headers(args["headers"])
      |> send_request(project, c)
    else
      {:error, "#{Enum.join(missing, ", ")} is required and can't be empty"}
    end
  end

  @doc "GETs a URL the API handed back (the next page), with the service's auth."
  def request_url(%Project{} = project, c, url) when is_binary(url),
    do: send_request([method: :get, url: url], project, c)

  defp send_request(opts, project, c) do
    with {:ok, auth} <- auth_options(project, c.auth) do
      opts =
        [retry: false, receive_timeout: 60_000, decode_body: false]
        |> Keyword.merge(opts)
        |> Keyword.merge(auth, fn
          :params, a, b -> a ++ b
          :headers, a, b -> List.wrap(a) ++ b
          _, _, b -> b
        end)
        # Tests point calls at a Req.Test stub.
        |> Keyword.merge(Application.get_env(:beamcode, :connector_req_options, []))

      case request_with_retry(c, opts, 3) do
        {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, to_string(body)}
        {:error, e} -> {:error, Exception.message(e)}
      end
    end
  end

  @doc """
  A body template filled from `values`: a string that is exactly `"{name}"`
  becomes that value as it is (a number stays a number, a missing one null).
  Nothing else is touched, so GraphQL queries keep their braces; their values
  go in `variables`.
  """
  def fill(template, values) when is_map(template),
    do: Map.new(template, fn {k, v} -> {k, fill(v, values)} end)

  def fill(template, values) when is_list(template), do: Enum.map(template, &fill(&1, values))

  def fill(template, values) when is_binary(template) do
    case Regex.run(~r/^\{(\w+)\}$/, template) do
      [_, key] -> values[key]
      nil -> template
    end
  end

  def fill(other, _values), do: other

  @doc "The `{placeholders}` a call's body template takes."
  def body_params(%{body: nil}), do: []

  def body_params(%{body: body}) do
    Regex.scan(~r/"\{(\w+)\}"/, Jason.encode!(body)) |> Enum.map(&List.last/1) |> Enum.uniq()
  end

  def body_params(_), do: []

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

  defp auth_options(_project, %{"type" => "none"}), do: {:ok, []}

  defp auth_options(project, %{"type" => type, "secret" => name} = auth) do
    case Vault.fetch(project, name) do
      {:ok, secret} ->
        case type do
          "bearer" -> {:ok, [auth: {:bearer, secret}]}
          "basic" -> {:ok, [auth: {:basic, secret}]}
          "header" -> {:ok, [headers: [{auth["header"] || "x-api-key", secret}]]}
          "query" -> {:ok, [params: [{auth["param"] || "api_key", secret}]]}
          other -> {:error, "unknown auth type #{other}"}
        end

      :error ->
        {:error, "secret #{name} is not set. Set it in the Project's API calls."}
    end
  end

  defp auth_options(_project, _), do: {:ok, []}

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
    shared = list()

    Projects.list_projects()
    |> Enum.filter(&Workspace.uses_gateway?/1)
    |> Enum.each(&sync_project(&1, shared))
  end

  @doc "`sync_all/0` for one Project (after its API calls changed)."
  def sync_project(project, shared \\ nil) do
    if Workspace.uses_gateway?(project) do
      rules =
        for c <- for_project(project, shared || list()), t <- c.tools, t.permission != "deny" do
          %{"action" => permission_action(c, t), "resource" => "*", "effect" => t.permission}
        end

      case Workspace.sync_opencode_json(project, rules) do
        :ok -> :ok
        error -> Logger.warning("opencode.json sync for #{project.name}: #{inspect(error)}")
      end

      Workspace.refresh_conventions(project)
    end

    :ok
  end

  @doc """
  Has the Project's chat write or change API calls from `description` (the
  user's words). Returns `{:ok, session_id}`.
  """
  def generate(%Project{} = project, user, description) do
    have =
      case all_for(project) do
        [] ->
          "It has none yet."

        services ->
          "It has: " <>
            Enum.map_join(services, "; ", fn c ->
              "#{c.name} (#{Enum.map_join(c.tools, ", ", & &1.name)})" <>
                if(c.source == "shared", do: " (shared, read-only here)", else: "")
            end) <> "."
      end

    prompt = """
    Add or change API calls in this Project (#{project.name}). In the user's words:

    #{description}

    #{have}

    1. Read the API's docs (webfetch) for the exact paths, parameters and auth.
    2. Write or update `#{@api_dir}/<service>.json`, one file per service, with only the calls asked for.#{if project.kind == "dataset", do: " In this Dataset, add the `tables` its read calls fill and make its changes write calls (the actions).", else: ""}
    3. If it needs a key, name it in `auth.secret` and ask for it with the `ask_token` tool, then wait.
    4. If the gateway already has the tool (`<service>_<call>`), try one read call; never a write.

    End with the calls you added, one line each, and say I can try them in the API calls tab.

    #{format_doc()}
    """

    with {:ok, session} <- Sessions.open(project, user, title: "API calls"),
         {:ok, _} <- Sessions.send_text(session["id"], prompt, project.directory) do
      {:ok, session["id"]}
    end
  end

  @doc "The service file format, for agents that write one."
  def format_doc do
    """
    One file per service: `.peon/api/<service>.json`. Each call in it shows up
    as `<service>_<call>` from the `gateway` MCP server, as `call:
    <service>.<call>` in a procedure step, and in the Project's API calls tab,
    where people inspect, edit and send it.

    ```json
    {
      "baseUrl": "https://api2.frontapp.com",
      "auth": { "type": "bearer", "secret": "FRONT_TOKEN" },
      "rateLimit": { "perMinute": 80 },
      "tools": {
        "list_conversations": ["GET", "/inboxes/{inbox}/conversations", "allow", "List conversations in an inbox"],
        "add_comment": ["POST", "/conversations/{id}/comments", "ask", "Add an internal comment"],
        "archive": ["PATCH", "/conversations/{id}", "deny"]
      }
    }
    ```

    - `auth.type`: `bearer`, `header` (add `"header": "X-Api-Key"`), `basic`
      (secret holds `user:password`), `query` (add `"param": "api_key"`) or `none`.
    - Each call is `[method, path, permission, description]`, named in
      lowercase snake_case. The description is all an agent sees, so say exactly
      what values look like: date formats (Unix seconds vs ISO), ID prefixes,
      query syntax, and how paging works.
      Permission: `allow` runs, `ask` waits for a person to approve each call,
      `deny` is never given to agents. Default: reads allow, writes ask,
      destructive deny.
    - `{placeholders}` in the path become required arguments. Every call also
      takes optional `query` and `body` objects.
    - Secret names are UPPER_SNAKE_CASE, one token per service. Ask for it with
      the gateway's `ask_token` tool (name, service, what kind and scopes, the
      link to make one): the user pastes it into a card that saves it to this
      Project's secrets. Never ask for a token in a message and never write one
      to a file. You can call with it but never read it.
    - A call that needs a fixed body (GraphQL) uses the long form:
      `"items": {"method": "POST", "path": "/graphql", "permission": "allow",
      "kind": "read", "description": "…", "body": {"query": "query($p: ID!,
      $after: String) {…}", "variables": {"p": "{project}", "after": "{after}"}}}`.
      A string that is exactly `"{name}"` is filled from the call's arguments;
      nothing inside the query is, so values go in `variables`. `kind` is
      `read` or `write` (default: GET reads, anything else writes).
    - In a Dataset, `"tables"` says what the read calls fill, synced every few
      minutes into data.sqlite (see the sqlite-schema skill):

      ```json
      "tables": {
        "conversations": {
          "call": "list_conversations", "args": {"inbox": "inb_1"},
          "rows": "_results", "id": "id",
          "columns": {"subject": "subject", "assignee": "assignee.email",
                      "tags": "tags[].name",
                      "created_at": {"path": "created_at", "type": "time"}},
          "next": "_pagination.next", "pages": 3, "every_minutes": 5
        }
      }
      ```

      `rows` is where the list is in the response, `id` each row's id, and
      each column a path in a row: keys joined by `.`, `[]` for every item of
      a list, `[0]` for one, `[key=value]` for the first whose key matches
      (`fieldValues.nodes[field.name=Status].name`). Types: text (default),
      integer, real, time (Unix seconds or ms to ISO) and json; `"options"`
      lists a column's values in order (a board's columns). Paging: `next`
      is where the next page's URL is, or `"cursor": {"from": "data.x.pageInfo.endCursor",
      "to": "after"}` passes the cursor back as `after`.
    - A Dataset's write calls are its actions: the agent calls them through
      the gateway, and views through `peon.act(call, row, args)`. Their
      permission is the action's level (allow: direct, ask: ask first, deny:
      off). A row's columns and `id` (its id on the service) fill the call's
      path and body, so `"/conversations/{id}"` acts on that row. `"patch":
      {"status": "{value}"}` shows the change on the row at once, before the
      next sync confirms it.
    - Rate limits: look up the API's limit and set `rateLimit.perMinute` a bit
      under it. Peon paces every call and retries HTTP 429 itself.
    - Verbose JSON: `"compact": true` drops `_links` and HTML `body` fields
      that have a plain `text` copy. Responses over 60 KB are cut, so prefer
      search endpoints and page sizes over listing everything.
    """
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
