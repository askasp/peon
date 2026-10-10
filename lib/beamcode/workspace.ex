defmodule Beamcode.Workspace do
  @moduledoc """
  The folder layout on the OpenCode server:

      <root>/
        setup/                 system project, admins only
          AGENTS.md
          connectors/*.json    one file per connector
        routines/
          AGENTS.md            shared by all routines
          .opencode/skill/     shared skills
          <name>/              a routine = its own project
            AGENTS.md
            opencode.json      gateway MCP server + connector permissions
            schedules.json
        code/<name>/           cloned or new git repos
        <name>/                chat projects

  `<root>` is `CHATOS_ROOT`, or `chatos/` inside the server's default folder.
  """
  require Logger
  alias Beamcode.{GitTokens, Opencode, Projects, Vault}
  alias Beamcode.Projects.Project

  def root do
    case :persistent_term.get({__MODULE__, :root}, nil) do
      nil ->
        root =
          Application.get_env(:beamcode, :chatos_root) ||
            case Opencode.location() do
              {:ok, %{"directory" => dir}} -> Path.join(dir, "chatos")
              _ -> nil
            end

        if root, do: :persistent_term.put({__MODULE__, :root}, root)
        root

      root ->
        root
    end
  end

  def gateway_url do
    Application.get_env(:beamcode, :gateway_url) ||
      "http://127.0.0.1:#{BeamcodeWeb.Endpoint.config(:http)[:port] || 4000}"
  end

  def mcp_url(%Project{id: id}), do: gateway_url() <> "/mcp/" <> mcp_token(id)

  # Deterministic, so opencode.json only changes when the project does.
  def mcp_token(project_id) do
    mac =
      :crypto.mac(:hmac, :sha256, mcp_key(), "mcp:#{project_id}")
      |> Base.url_encode64(padding: false)

    "#{project_id}.#{binary_part(mac, 0, 32)}"
  end

  def verify_mcp_token(token) do
    with [id, _] <- String.split(token, ".", parts: 2),
         {id, ""} <- Integer.parse(id),
         true <- Plug.Crypto.secure_compare(mcp_token(id), token) do
      {:ok, id}
    else
      _ -> :error
    end
  end

  defp mcp_key, do: Application.fetch_env!(:beamcode, BeamcodeWeb.Endpoint)[:secret_key_base]

  def setup_project, do: Projects.get_by_name("setup")

  @doc "Creates the setup project and the shared routines folder once. Idempotent."
  def ensure_bootstrap do
    if :persistent_term.get({__MODULE__, :bootstrapped}, false) do
      :ok
    else
      with root when is_binary(root) <- root(),
           :ok <- ensure_root(root),
           :ok <- ensure_setup(root),
           :ok <- write_new(root, "routines/AGENTS.md", routines_agents_md()) do
        :persistent_term.put({__MODULE__, :bootstrapped}, true)
        restore_git_tokens()
        :ok
      else
        error ->
          Logger.warning("workspace bootstrap failed: #{inspect(error)}")
          :error
      end
    end
  end

  # OpenCode only accepts existing folders as a location, so create the root
  # from the server's default folder first.
  defp ensure_root(root) do
    case Opencode.location() do
      {:ok, %{"directory" => server_dir}} -> shell(server_dir, "mkdir -p #{q(root)}")
      error -> error
    end
  end

  defp ensure_setup(root) do
    dir = Path.join(root, "setup")

    with :ok <- write_managed(root, "setup/AGENTS.md", setup_agents_md()),
         :ok <- write_new(root, "setup/connectors/README.md", "Connector files live here.\n") do
      case setup_project() do
        nil ->
          {:ok, project} =
            Projects.insert_project(
              %{name: "setup", kind: "system", directory: dir, scope: "team"},
              nil
            )

          finish_project(project)
          :ok

        _ ->
          :ok
      end
    end
  end

  defp write_new(dir, path, content) do
    case Opencode.read_file(dir, path) do
      {:ok, _} -> :ok
      {:error, :enoent} -> write(dir, path, content)
      error -> error
    end
  end

  # Earlier versions of the setup AGENTS.md this app wrote. A file that still
  # matches one of them was never edited by hand, so it's safe to update.
  @previous_setup_agents [
    "b25b0784a6a43e68945b0171497b162826515e5616b1eebc7d61a917c88497c4",
    "e6cab37c52f5807af0ada75097013bffcc7797c5c235d81fb762f4941d908ba4",
    "e14f4c7410e79a5b7c8bcf832175c48c9bcc4045c5fa221dfe7fbb913015995b",
    "3166a3f2888ce23b6be720a41e79238522ec23fa286adf92df1013352543569c"
  ]

  defp write_managed(dir, path, content) do
    case Opencode.read_file(dir, path) do
      {:ok, ^content} ->
        :ok

      {:ok, old} ->
        hash = :crypto.hash(:sha256, old) |> Base.encode16(case: :lower)
        if hash in @previous_setup_agents, do: write(dir, path, content), else: :ok

      {:error, :enoent} ->
        write(dir, path, content)

      error ->
        error
    end
  end

  @doc "Git repos OpenCode already knows that aren't Peon projects yet (for cloning in place)."
  def known_repos do
    taken = MapSet.new(Projects.list_projects(), & &1.directory)
    root = root()

    case Opencode.projects() do
      {:ok, list} when is_list(list) ->
        for p <- list,
            p["vcs"] == "git",
            dir = p["canonical"],
            is_binary(dir),
            not MapSet.member?(taken, dir),
            root == nil or not String.starts_with?(dir, root <> "/"),
            not String.contains?(dir, "/worktree/"),
            do: dir

      _ ->
        []
    end
    |> Enum.sort()
  end

  @doc "Folders in routines/ that aren't Peon projects yet (e.g. made by a setup session)."
  def unregistered_routines do
    with root when is_binary(root) <- root(),
         {:ok, entries} <- Opencode.list_dir(root, "routines") do
      taken = MapSet.new(Projects.list_projects(), & &1.directory)

      for %{"type" => "directory", "path" => path} <- entries,
          name = Path.basename(path),
          not String.starts_with?(name, "."),
          not MapSet.member?(taken, Path.join([root, "routines", name])),
          do: name
    else
      _ -> []
    end
    |> Enum.sort()
  end

  defp write(dir, path, content) do
    case Opencode.write_file(dir, path, content) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Creates a project folder on the server and records it.

  attrs: name, kind, scope, and per kind:
    * code: `source` – git URL to clone, an absolute folder path to use, or blank for a new repo;
      `github_token` – optional, for a github.com `source`: cloned over HTTPS with it, and
      sessions push and open PRs with it; `always_worktree`
    * routine: `description`
  """
  def create_project(attrs, user) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    name = attrs["name"] |> to_string() |> String.trim()
    kind = attrs["kind"]
    root = root()
    source = String.trim(attrs["source"] || "")
    token = if kind == "code", do: String.trim(attrs["github_token"] || ""), else: ""

    github_repo =
      case kind == "code" && GitTokens.parse_github(source) do
        {:ok, repo} -> repo
        _ -> nil
      end

    {dir, prepare} =
      case kind do
        "code" ->
          source =
            if github_repo && token != "", do: GitTokens.https_url(github_repo), else: source

          code_dir(root, name, source)

        "routine" ->
          {Path.join([root, "routines", name]), &prepare_routine(root, &1, name, attrs)}

        _ ->
          {Path.join(root, name), &prepare_chat(root, &1)}
      end

    project_attrs = %{
      name: name,
      kind: kind,
      directory: dir,
      scope: attrs["scope"] || "team",
      always_worktree: attrs["always_worktree"] in [true, "true"],
      github_repo: github_repo
    }

    changeset = Projects.change_project(%Project{}, project_attrs)

    cond do
      root == nil ->
        {:error, Ecto.Changeset.add_error(changeset, :name, "OpenCode server is not reachable")}

      not changeset.valid? ->
        {:error, %{changeset | action: :insert}}

      true ->
        result =
          with :ok <- prepare_token(github_repo, token),
               :ok <- clone_hint(prepare.(dir), github_repo, token),
               {:ok, project} <- Projects.insert_project(project_attrs, user),
               :ok <- store_token(project, token, user) do
            {:ok, finish_project(project)}
          end

        # The clone wrote the token to the server before the project existed.
        if token != "" and not match?({:ok, _}, result), do: GitTokens.sync()

        case result do
          {:ok, project} ->
            {:ok, project}

          {:error, %Ecto.Changeset{} = cs} ->
            {:error, cs}

          {:error, reason} ->
            {:error, Ecto.Changeset.add_error(changeset, :name, format_error(reason))}
        end
    end
  end

  defp prepare_token(_repo, ""), do: :ok
  defp prepare_token(nil, _token), do: {:error, "a GitHub token needs a github.com URL"}

  defp prepare_token(repo, token) do
    with :ok <- GitTokens.check(repo, token), do: GitTokens.sync([{repo, token}])
  end

  defp clone_hint({:error, msg}, repo, "") when is_binary(repo) and is_binary(msg),
    do: {:error, msg <> " · Private repo? Add a GitHub token."}

  defp clone_hint(result, _repo, _token), do: result

  defp store_token(_project, "", _user), do: :ok

  defp store_token(project, token, user) do
    case Vault.put(GitTokens.secret_name(project), token, user) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp restore_git_tokens do
    case GitTokens.restore() do
      :ok -> :ok
      error -> Logger.warning("restoring GitHub tokens failed: #{inspect(error)}")
    end
  end

  defp format_error({_status, msg}) when is_binary(msg), do: msg
  defp format_error(msg) when is_binary(msg), do: msg
  defp format_error(other), do: inspect(other)

  # Shell commands run from the root folder: OpenCode needs an existing folder
  # as the location, and the project folder may not exist yet.
  defp code_dir(root, name, source) do
    cond do
      String.starts_with?(source, "/") ->
        {source, fn dir -> shell(root, "test -d #{q(dir)}") end}

      source != "" ->
        {Path.join([root, "code", name]),
         fn dir ->
           shell(root, "mkdir -p #{q(Path.dirname(dir))} && git clone -q #{q(source)} #{q(dir)}")
         end}

      true ->
        init =
          "git init -q && git -c user.name=peon -c user.email=peon@localhost commit -q --allow-empty -m 'Initial commit'"

        {Path.join([root, "code", name]),
         fn dir ->
           shell(
             root,
             "mkdir -p #{q(dir)} && cd #{q(dir)} && (git rev-parse --git-dir >/dev/null 2>&1 || (#{init}))"
           )
         end}
    end
  end

  defp shell(at, cmd) do
    case Opencode.run_shell(at, cmd) do
      {:ok, 0, _} -> :ok
      {:ok, code, out} -> {:error, "command failed (#{code}): #{String.slice(out, -300, 300)}"}
      error -> error
    end
  end

  defp q(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp prepare_routine(root, dir, name, attrs) do
    rel = Path.relative_to(dir, root)
    desc = String.trim(attrs["description"] || "")

    agents = """
    # #{name}

    #{if desc == "", do: "Describe this routine's one job here.", else: desc}
    """

    skill = name |> String.split("-") |> List.last()
    routine = Jason.encode!(%{"run" => "/" <> skill, "inputs" => %{}}, pretty: true) <> "\n"

    with :ok <- write_new(root, Path.join(rel, "AGENTS.md"), agents),
         :ok <- write_new(root, Path.join(rel, "routine.json"), routine) do
      write_new(root, Path.join(rel, "schedules.json"), "{}\n")
    end
  end

  defp prepare_chat(root, dir) do
    write_new(root, Path.join(Path.relative_to(dir, root), "AGENTS.md"), """
    # Chat

    General chat. When you make something worth keeping (a document, data, a diagram),
    save it as a file in `artifacts/` and mention the path.
    """)
  end

  defp finish_project(project) do
    project =
      case Opencode.location(project.directory) do
        {:ok, %{"project" => %{"id" => id}}} -> Projects.put_oc_project_id(project, id)
        _ -> project
      end

    if uses_gateway?(project), do: sync_opencode_json(project, [])
    project
  end

  def uses_gateway?(%Project{kind: kind}), do: kind in ~w(routine chat system)

  @gateway "gateway"
  def gateway_server, do: @gateway

  @doc """
  Writes the gateway MCP server and connector permissions into the project's
  opencode.json, keeping everything else in the file. `rules` are
  `%{"action" => _, "resource" => "*", "effect" => _}` maps. Only writes on change.
  """
  def sync_opencode_json(%Project{} = project, rules) do
    dir = project.directory

    current =
      case Opencode.read_file(dir, "opencode.json") do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, map} when is_map(map) -> {:ok, map}
            _ -> :invalid
          end

        {:error, :enoent} ->
          {:ok, %{}}

        error ->
          error
      end

    with {:ok, config} <- current do
      kept =
        (config["permissions"] || [])
        |> Enum.reject(&String.starts_with?(to_string(&1["action"]), @gateway <> "_"))

      updated =
        config
        |> Map.put_new("$schema", "https://opencode.ai/config.json")
        |> put_in([Access.key("mcp", %{}), Access.key("servers", %{}), @gateway], %{
          "type" => "remote",
          "url" => mcp_url(project)
        })
        |> Map.put("permissions", kept ++ rules)
        |> then(fn c -> if c["permissions"] == [], do: Map.delete(c, "permissions"), else: c end)

      if updated == config,
        do: :ok,
        else: write(dir, "opencode.json", Jason.encode!(updated, pretty: true) <> "\n")
    else
      :invalid -> {:error, "opencode.json is not valid JSON"}
      error -> error
    end
  end

  defp routines_agents_md do
    """
    # Routines

    Shared by all routines: company, tone, policies. Each folder here is one routine
    that does one job. Shared skills live in `.opencode/skill/`.
    """
  end

  defp setup_agents_md do
    """
    # Setup

    This is the setup project. Admins use sessions here to connect APIs (connectors)
    and to set up routines. Be brief and concrete.

    ## Connectors

    A connector is one JSON file: `connectors/<name>.json`. The gateway reads every file
    in that folder and exposes each tool as an MCP tool to the projects listed in
    `projects`. This setup project can always use every connector, so you can test it.
    The tools show up from the `gateway` MCP server, named `<connector>_<tool>`.

    ```json
    {
      "name": "front",
      "baseUrl": "https://api2.frontapp.com",
      "auth": { "type": "bearer", "secret": "FRONT_TOKEN" },
      "tools": {
        "list_conversations": ["GET", "/inboxes/{inbox}/conversations", "allow", "List conversations in an inbox"],
        "add_comment": ["POST", "/conversations/{id}/comments", "ask", "Add an internal comment"],
        "archive": ["PATCH", "/conversations/{id}", "deny"]
      },
      "projects": ["front-digest"]
    }
    ```

    - `auth.type`: `bearer`, `header` (add `"header": "X-Api-Key"`), `basic`
      (secret holds `user:password`), `query` (add `"param": "api_key"`) or `none`.
    - Each tool is `[method, path, permission, description]`. The description is all
      a routine sees, so say exactly what values look like: date formats (Unix
      seconds vs ISO), ID prefixes, query syntax, and how paging works.
      Permission: `allow` runs, `ask` waits for a person to approve each call,
      `deny` is never exposed. Default: reads allow, writes ask, destructive deny.
    - `{placeholders}` in the path become required tool arguments. Every tool also
      takes optional `query` and `body` objects.
    - `name` must match the file name. Secret names are UPPER_SNAKE_CASE.
    - Rate limits: look up the API's limit in its docs and set
      `"rateLimit": {"perMinute": N}` a bit under it. The gateway paces every
      call to that connector (all sessions together), and on HTTP 429 it waits
      as long as the API asks and retries. Skills must not sleep or retry 429s
      themselves.
    - Verbose JSON: set `"compact": true` to drop `_links` and HTML `body`
      fields that have a plain `text` copy. Responses over 60 KB are cut, so
      prefer search endpoints and page sizes (`limit`) over listing everything.

    ## Secrets

    Never ask anyone to paste a token into this chat, and never write one to a file.
    Tell them to open **Connectors** in the sidebar and set the secret named in
    `auth.secret`. It goes to the vault. Then test the connector with a read call.

    ## Setting up a connector

    1. Read the API docs (webfetch).
    2. Write `connectors/<name>.json` with the tools the user needs.
    3. Ask the user to set the secret on the Connectors page.
    4. Call one or two read tools to test it, and say what you found.
    5. Ask which projects should get it and update `projects`.

    ## Routines and schedules

    Routines live in `../routines/<name>/`. `routine.json` says how a run starts:
    the prompt sent to a new session, and optional inputs the Run button asks for.

    ```json
    { "run": "/digest since {since}",
      "inputs": { "since": { "default": "last run", "options": ["last run", "today", "this week"] },
                  "inboxes": { "default": ["Support"], "multi": true, "options": ["Support", "Billing"] } } }
    ```

    A run's final answer is shown as its result, so end the skill with the result
    itself (markdown), not with commentary.

    Skills that read an API should narrow first (search by keywords, dates,
    status) and only then read details, one call per item. Reading everything
    and filtering afterwards hits rate limits.

    A routine's schedules are in its `schedules.json` (leave `prompt` out to use
    routine.json with its defaults):

    ```json
    { "morning-digest": { "cron": "0 8 * * 1-5", "prompt": "/digest since the last run",
                          "scope": "team", "owner": "aksel" } }
    ```

    `cron` is five fields in server local time. `scope` is `team` or `me`.

    A routine folder you create shows up in the app only after someone adds it.
    You can't do that yourself: tell the user to click **+** next to Routines in the
    sidebar and pick the folder under "Already on the server".
    """
  end
end
