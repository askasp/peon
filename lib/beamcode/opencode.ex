defmodule Beamcode.Opencode do
  @moduledoc """
  Thin client for the OpenCode v2 server API (`/api/*`).

  Configured with `OPENCODE_URL`, `OPENCODE_USERNAME` and `OPENCODE_PASSWORD`.
  """

  def config, do: Application.get_env(:beamcode, :opencode, [])

  def base_url, do: Keyword.get(config(), :url, "http://127.0.0.1:4096")

  def req(opts \\ []) do
    cfg = config()

    auth =
      case Keyword.get(cfg, :password) do
        nil -> []
        "" -> []
        pw -> [auth: {:basic, "#{Keyword.get(cfg, :username, "opencode")}:#{pw}"}]
      end

    Req.new([base_url: base_url(), retry: false, receive_timeout: 30_000] ++ auth)
    |> Req.merge(Keyword.merge(Keyword.get(cfg, :req_options, []), opts))
  end

  defp loc(nil), do: []
  defp loc(dir), do: [{"location[directory]", dir}]

  defp request(method, path, opts) do
    start = System.monotonic_time()

    {result, status, bytes} =
      case Req.request(req(), [method: method, url: path] ++ opts) do
        {:ok, %Req.Response{status: status, headers: headers, body: body}}
        when status in 200..299 ->
          {{:ok, body}, status, content_length(headers, body)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {{:error, {status, error_message(body)}}, status, nil}

        {:error, exception} ->
          {{:error, {:transport, Exception.message(exception)}}, :transport, nil}
      end

    Beamcode.Instrument.report(
      "oc #{method |> to_string() |> String.upcase()} #{trim_path(path)}",
      System.monotonic_time() - start,
      meta_drop_nil(%{status: status, bytes: bytes})
    )

    result
  end

  # The response's size, from its `content-length` (JSON is already decoded to a
  # map by the time we see it) or the raw body for streams like file reads.
  defp content_length(headers, body) do
    case Req.Response.get_header(%Req.Response{headers: headers}, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        if is_binary(body), do: byte_size(body), else: nil
    end
  end

  # Request logs stay short when a path carries a long file name or query.
  defp trim_path(path) when is_binary(path) do
    if byte_size(path) > 160, do: binary_part(path, 0, 160) <> "…", else: path
  end

  defp trim_path(path), do: inspect(path)

  defp meta_drop_nil(meta),
    do: for({k, v} <- meta, v != nil, into: %{}, do: {k, v})

  defp error_message(%{"message" => m}), do: m
  defp error_message(%{"_tag" => t}), do: t
  defp error_message(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp error_message(body), do: inspect(body)

  defp data({:ok, %{"data" => data}}), do: {:ok, data}
  defp data(other), do: other

  ## Server

  def info, do: request(:get, "/api/info", [])

  def location(dir \\ nil), do: request(:get, "/api/location", params: loc(dir))

  def models, do: request(:get, "/api/model", []) |> data()

  @doc "The model a session uses when none is picked (a folder's opencode.json can set it)."
  def default_model(dir \\ nil),
    do: request(:get, "/api/model/default", params: loc(dir)) |> data()

  @doc """
  The agents for a folder. OpenCode answers `[]` while it's still loading a
  folder it hasn't seen (it always has at least `build` once loaded), so an
  empty list is retried for a few seconds.
  """
  def agents(dir \\ nil, tries \\ 10) do
    case request(:get, "/api/agent", params: loc(dir)) |> data() do
      {:ok, []} when tries > 1 ->
        Process.sleep(300)
        agents(dir, tries - 1)

      result ->
        result
    end
  end

  @doc "Makes OpenCode re-read config, skills and instructions for a folder."
  def reload_location(dir), do: request(:post, "/api/location/reload", params: loc(dir))

  @doc "Projects (folders) the OpenCode server already knows."
  def projects, do: request(:get, "/api/project", [])

  def skills(dir), do: request(:get, "/api/skill", params: loc(dir)) |> data()

  def commands(dir), do: request(:get, "/api/command", params: loc(dir)) |> data()

  ## Model providers
  #
  # OpenCode calls a provider's sign-in an integration. Credentials belong to the
  # server, so every session on it shares them.

  def integrations, do: request(:get, "/api/integration", []) |> data()

  def connect_key(integration_id, key, answer \\ nil) do
    request(:post, "/api/integration/#{integration_id}/connect/key",
      json: %{key: key, answer: answer}
    )
  end

  @doc "Starts an OAuth sign-in. Returns the attempt: attemptID, url, instructions, mode."
  def start_oauth(integration_id, method_id, answer \\ nil) do
    request(:post, "/api/integration/#{integration_id}/connect/oauth",
      json: %{methodID: method_id, answer: answer}
    )
    |> data()
  end

  @doc "An attempt's status: pending, complete, failed or expired."
  def oauth_status(integration_id, attempt_id) do
    request(:get, "/api/integration/#{integration_id}/connect/oauth/#{attempt_id}", [])
    |> data()
  end

  @doc "Finishes a `code` mode attempt with the code the provider showed."
  def complete_oauth(integration_id, attempt_id, code) do
    request(:post, "/api/integration/#{integration_id}/connect/oauth/#{attempt_id}/complete",
      json: %{code: code}
    )
  end

  @doc """
  Finishes an `auto` mode attempt for a browser on another machine: the
  provider redirected it to the server's own `http://127.0.0.1:<port>/…`
  listener, which it can't reach, so the user pastes that address and this
  requests it on the server's behalf. Only loopback addresses are accepted.
  """
  def forward_oauth_callback(url) do
    with %URI{scheme: "http", host: host, port: port} = uri
         when host in ["127.0.0.1", "localhost"] and is_integer(port) <-
           URI.parse(String.trim(url || "")),
         target = %{uri | host: callback_host()} |> URI.to_string(),
         {:ok, %Req.Response{status: status, body: body}} <-
           Req.new(url: target, retry: false, redirect: false, receive_timeout: 15_000)
           |> Req.merge(Keyword.get(config(), :req_options, []))
           |> Req.request() do
      if status < 400, do: :ok, else: {:error, {status, error_message(body)}}
    else
      %URI{} -> {:error, "paste the http://127.0.0.1:… address your browser ended on"}
      {:error, e} -> {:error, {:transport, Exception.message(e)}}
    end
  end

  # The listener is on the OpenCode server's loopback: reachable as 127.0.0.1
  # when this app runs on the same machine, which is how it is deployed.
  defp callback_host do
    case URI.parse(base_url()).host do
      h when h in ["localhost", "127.0.0.1", "::1"] -> "127.0.0.1"
      h -> h
    end
  end

  def cancel_oauth(integration_id, attempt_id),
    do: request(:delete, "/api/integration/#{integration_id}/connect/oauth/#{attempt_id}", [])

  def remove_credential(credential_id),
    do: request(:delete, "/api/credential/#{credential_id}", [])

  ## Sessions

  def list_sessions(params \\ []) do
    params = Enum.reject(params, fn {_, v} -> is_nil(v) end)
    request(:get, "/api/session", params: params) |> data()
  end

  def get_session(id), do: request(:get, "/api/session/#{id}", []) |> data()

  def create_session(attrs), do: request(:post, "/api/session", json: attrs) |> data()

  def update_session(id, attrs), do: request(:patch, "/api/session/#{id}", json: attrs) |> data()

  def delete_session(id), do: request(:delete, "/api/session/#{id}", [])

  def active_sessions, do: request(:get, "/api/session/active", []) |> data()

  def messages(id, limit \\ 200) do
    request(:get, "/api/session/#{id}/message", params: [limit: limit, order: "desc"])
    |> data()
    |> case do
      {:ok, msgs} -> {:ok, Enum.reverse(msgs)}
      other -> other
    end
  end

  @doc """
  One page of a session's messages for windowed loading: the newest `limit`
  messages, oldest first. Pass a previous page's `next` cursor to get the page
  just older than it. `{:ok, %{messages: [...], next: cursor | nil}}`.
  """
  def messages_page(id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)

    params =
      case Keyword.get(opts, :cursor) do
        c when is_binary(c) -> [limit: limit, cursor: c]
        _ -> [limit: limit, order: "desc"]
      end

    case request(:get, "/api/session/#{id}/message", params: params) do
      {:ok, %{"data" => messages} = body} when is_list(messages) ->
        {:ok, %{messages: Enum.reverse(messages), next: get_in(body, ["cursor", "next"])}}

      other ->
        other
    end
  end

  def prompt(id, body), do: request(:post, "/api/session/#{id}/prompt", json: body) |> data()

  def command(id, body), do: request(:post, "/api/session/#{id}/command", json: body) |> data()

  def interrupt(id), do: request(:post, "/api/session/#{id}/interrupt", [])

  def compact(id), do: request(:post, "/api/session/#{id}/compact", json: %{})

  def switch_model(id, model),
    do: request(:post, "/api/session/#{id}/model", json: %{model: model}) |> data()

  def switch_agent(id, agent),
    do: request(:post, "/api/session/#{id}/agent", json: %{agent: agent}) |> data()

  def diff(id), do: request(:get, "/api/session/#{id}/diff", []) |> data()

  ## Permissions

  def permission_requests(dir),
    do: request(:get, "/api/permission/request", params: loc(dir)) |> data()

  def session_permissions(id), do: request(:get, "/api/session/#{id}/permission", []) |> data()

  def reply_permission(session_id, request_id, decision)
      when decision in ["once", "always", "reject"] do
    request(:post, "/api/session/#{session_id}/permission/#{request_id}/reply",
      json: %{decision: decision}
    )
  end

  ## Forms: questions the agent asks (OpenCode's question tool)

  def session_forms(id), do: request(:get, "/api/session/#{id}/form", []) |> data()

  @doc "`answer` maps each field's key to its value (a string, number, boolean or list of strings)."
  def reply_form(session_id, form_id, answer) when is_map(answer),
    do:
      request(:post, "/api/session/#{session_id}/form/#{form_id}/reply", json: %{answer: answer})

  def cancel_form(session_id, form_id),
    do: request(:delete, "/api/session/#{session_id}/form/#{form_id}", [])

  ## Files, shell, worktrees

  def read_file(dir, path) do
    start = System.monotonic_time()

    result =
      case Req.request(req(),
             method: :get,
             url: "/api/fs/read/" <> URI.encode(path),
             params: loc(dir),
             decode_body: false
           ) do
        {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
        {:ok, %Req.Response{status: 404}} -> {:error, :enoent}
        {:ok, %Req.Response{status: s, body: b}} -> {:error, {s, error_message(b)}}
        {:error, e} -> {:error, {:transport, Exception.message(e)}}
      end

    {status, bytes} =
      case result do
        {:ok, body} -> {200, byte_size(body)}
        {:error, :enoent} -> {404, nil}
        {:error, {s, _}} -> {s, nil}
        {:error, other} -> {other, nil}
      end

    Beamcode.Instrument.report(
      "oc GET /api/fs/read #{trim_path(path)}",
      System.monotonic_time() - start,
      meta_drop_nil(%{status: status, bytes: bytes})
    )

    result
  end

  def write_file(dir, path, content) do
    request(:post, "/api/experimental/fs/write",
      params: loc(dir) ++ [path: path],
      body: content,
      headers: [{"content-type", "application/octet-stream"}]
    )
    |> data()
  end

  def list_dir(dir, path \\ ".") do
    request(:get, "/api/fs/list", params: loc(dir) ++ [path: path]) |> data()
  end

  @doc "Fuzzy-finds files and folders under `dir`. Returns `[%{\"path\" => …, \"type\" => …}]`."
  def find_files(dir, query, limit \\ 20) do
    request(:get, "/api/fs/find", params: loc(dir) ++ [query: query, limit: limit]) |> data()
  end

  @doc "Runs a shell command at `dir` and waits for it to finish. Returns {:ok, exit, output}."
  def run_shell(dir, command, timeout_ms \\ 120_000) do
    Beamcode.Instrument.span("oc shell #{trim_path(String.replace(command, ~r/\s+/, " "))}", fn ->
      with {:ok, %{"id" => id}} <-
             request(:post, "/api/shell",
               params: loc(dir),
               json: %{command: command, timeout: timeout_ms}
             )
             |> data() do
        wait_shell(dir, id, System.monotonic_time(:millisecond) + timeout_ms + 5_000, 10)
      end
    end)
  end

  # Poll while the command runs, starting at `wait` ms and backing off to
  # `@shell_poll_max`: a command that finishes in tens of ms (most of them)
  # shouldn't wait a fixed 300 ms. The whole call is timed by `run_shell`.
  @shell_poll_max 200

  defp wait_shell(dir, id, deadline, wait) do
    case request(:get, "/api/shell/#{id}", params: loc(dir)) |> data() do
      {:ok, %{"status" => "running"}} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :timeout}
        else
          Process.sleep(wait)
          wait_shell(dir, id, deadline, min(wait * 2, @shell_poll_max))
        end

      {:ok, info} ->
        output =
          case request(:get, "/api/shell/#{id}/output", params: loc(dir)) |> data() do
            {:ok, %{"output" => out}} -> out
            _ -> ""
          end

        {:ok, info["exit"], output}

      error ->
        error
    end
  end

  @doc "A new worktree; `opts`: `:branch` (the ref to check out, detached) and `:name` (its folder)."
  def create_worktree(oc_project_id, opts \\ []) do
    body =
      opts
      |> Keyword.take([:branch, :name])
      |> Map.new()
      |> Map.put(:projectID, oc_project_id)

    request(:post, "/api/worktree", json: body) |> data()
  end
end
