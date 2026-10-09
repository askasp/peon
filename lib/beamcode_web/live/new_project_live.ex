defmodule BeamcodeWeb.NewProjectLive do
  @moduledoc "New project: code (clone or new repo), routine (one job) or chat."
  use BeamcodeWeb, :live_view
  alias Beamcode.{Connectors, GitTokens, Opencode, Projects, Sessions, Vault, Workspace}
  alias BeamcodeWeb.Shell

  @kinds [
    {"code", "Code", "Clone a repository, or start an empty one. Sessions code in it."},
    {"routine", "Routine", "A folder with instructions and skills. Does one job."},
    {"chat", "Chat", "General chat. Files it makes are artifacts."}
  ]

  @impl true
  def mount(params, _session, socket) do
    kind = if params["kind"] in ~w(code routine chat), do: params["kind"], else: "code"

    {:ok,
     socket
     |> assign(page_title: "New project", kinds: @kinds, creating: false, error: nil)
     |> assign(connectors: [], secrets: MapSet.new(), known_repos: [], known_routines: [])
     |> assign_form(%{"kind" => kind, "scope" => "team", "always_worktree" => "false"})
     |> start_async(:connectors, fn -> {Connectors.list(), Vault.names()} end)
     |> start_async(:known_repos, &known_repos/0)
     |> start_async(:known_routines, &Workspace.unregistered_routines/0)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = params["kind"]

    socket =
      if kind in ~w(code routine chat) and kind != socket.assigns.form.params["kind"],
        do:
          assign_form(
            socket,
            Map.merge(socket.assigns.form.params, %{"kind" => kind, "import" => "false"})
          ),
        else: socket

    {:noreply, socket}
  end

  defp assign_form(socket, params) do
    errors =
      case params["name"] do
        nil ->
          []

        "" ->
          []

        name ->
          if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name),
            do: [],
            else: [name: {"lowercase letters, digits and dashes", []}]
      end

    assign(socket, :form, to_form(params, as: :project, errors: errors))
  end

  @impl true
  def handle_event("kind", %{"kind" => kind}, socket) do
    {:noreply, push_patch(socket, to: ~p"/new?kind=#{kind}")}
  end

  def handle_event("pick_repo", %{"path" => path}, socket) do
    params = socket.assigns.form.params
    name = if params["name"] in [nil, ""], do: slug(Path.basename(path)), else: params["name"]
    {:noreply, assign_form(socket, Map.merge(params, %{"source" => path, "name" => name}))}
  end

  # A routine folder that already exists on the server: keep its files, don't draft.
  def handle_event("pick_routine", %{"name" => name}, socket) do
    params = socket.assigns.form.params

    params =
      if params["import"] == "true" and params["name"] == name,
        do: Map.merge(params, %{"import" => "false", "name" => ""}),
        else: Map.merge(params, %{"import" => "true", "name" => name})

    {:noreply, assign_form(socket, params)}
  end

  def handle_event("validate", %{"project" => params}, socket) do
    {:noreply, assign_form(socket, Map.merge(socket.assigns.form.params, params))}
  end

  def handle_event("create", %{"project" => params}, socket) do
    params = Map.merge(socket.assigns.form.params, params)
    user = socket.assigns.current_scope.user
    granted = for {name, "true"} <- params["connectors"] || %{}, do: name

    socket =
      socket
      |> assign(creating: true, error: nil)
      |> assign_form(params)
      |> start_async(:create, fn ->
        with {:ok, project} <- Workspace.create_project(params, user) do
          if project.kind == "routine" and granted != [] do
            Enum.each(granted, &Connectors.set_granted(&1, project.name, true))
            Connectors.sync_all()
          end

          {:ok, project, granted}
        end
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:connectors, {:ok, {connectors, secrets}}, socket) do
    {:noreply,
     assign(socket, connectors: Enum.filter(connectors, &(&1.error == nil)), secrets: secrets)}
  end

  def handle_async(:connectors, _, socket), do: {:noreply, socket}

  def handle_async(:known_repos, {:ok, repos}, socket),
    do: {:noreply, assign(socket, known_repos: repos)}

  def handle_async(:known_repos, _, socket), do: {:noreply, socket}

  def handle_async(:known_routines, {:ok, names}, socket),
    do: {:noreply, assign(socket, known_routines: names)}

  def handle_async(:known_routines, _, socket), do: {:noreply, socket}

  def handle_async(:create, {:ok, {:ok, project, granted}}, socket) do
    socket = assign(socket, creating: false)

    case project.kind do
      "routine" ->
        if importing?(socket.assigns.form.params),
          do: {:noreply, push_navigate(socket, to: ~p"/p/#{project.id}")},
          else: {:noreply, draft_routine(socket, project, granted)}

      _ ->
        {:noreply, push_navigate(socket, to: ~p"/p/#{project.id}")}
    end
  end

  def handle_async(:create, {:ok, {:error, %Ecto.Changeset{} = cs}}, socket) do
    msg =
      cs.errors
      |> Enum.map_join(", ", fn {field, {m, _}} -> "#{field} #{m}" end)

    {:noreply, assign(socket, creating: false, error: msg)}
  end

  def handle_async(:create, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, creating: false, error: Shell.format_error(reason))}

  def handle_async(:create, {:exit, reason}, socket),
    do: {:noreply, assign(socket, creating: false, error: inspect(reason))}

  # Starts a session in the new routine that drafts AGENTS.md and its skill.
  defp draft_routine(socket, project, granted) do
    user = socket.assigns.current_scope.user
    desc = socket.assigns.form.params["description"] || ""
    skill = skill_name(project.name)

    tools =
      for c <- socket.assigns.connectors,
          c.name in granted,
          t <- c.tools,
          t.permission != "deny",
          do: Connectors.tool_name(c, t)

    not_ready =
      for c <- socket.assigns.connectors,
          c.name in granted,
          not Connectors.ready?(c, socket.assigns.secrets),
          do: c.name

    connector_hint =
      cond do
        tools == [] -> "It has no connectors yet."
        true -> "It may use these MCP tools from the gateway server: #{Enum.join(tools, ", ")}."
      end

    prompt = """
    This is a new routine called #{project.name}. Its one job, in the user's words:

    #{desc}

    Draft it:
    1. Rewrite AGENTS.md as short, concrete instructions for this job: what to read, what to output, limits.
    2. Create one skill at .opencode/skill/#{skill}/SKILL.md (frontmatter with name and description) that does the job end to end, so it can be run as /#{skill}. Its last message must be the result itself, in markdown.
    3. If the job has choices worth asking for on each run (a time range, which inboxes…), add them as inputs in routine.json and use them in "run", like "/#{skill} since {since}". Otherwise leave routine.json as it is.

    #{connector_hint} Keep both files short. Don't run the job now; end by telling me to try /#{skill}.
    """

    with {:ok, session} <- Sessions.start(project, user, title: "Set up #{project.name}"),
         {:ok, _} <- Sessions.send_text(session["id"], prompt, project.directory) do
      socket =
        if not_ready != [],
          do:
            put_flash(
              socket,
              :info,
              "#{Enum.join(not_ready, ", ")} needs its secret. Set it on Connectors."
            ),
          else: socket

      push_navigate(socket, to: ~p"/s/#{session["id"]}")
    else
      {:error, reason} ->
        socket
        |> put_flash(
          :error,
          "Created, but the setup session failed: #{Shell.format_error(reason)}"
        )
        |> push_navigate(to: ~p"/p/#{project.id}")
    end
  end

  # Git repos OpenCode already knows that aren't Peon projects yet.
  defp known_repos do
    taken = MapSet.new(Projects.list_projects(), & &1.directory)
    root = Workspace.root()

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

  defp slug(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9-]+/, "-") |> String.trim("-")

  defp importing?(params), do: params["import"] == "true"

  defp github?(params), do: match?({:ok, _}, GitTokens.parse_github(params["source"]))

  defp skill_name(name), do: name |> String.split("-") |> List.last()

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :kind, assigns.form.params["kind"])

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns}>
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-[640px] mx-auto px-8 py-10 flex flex-col gap-6">
          <span class="text-[20px] font-semibold">New project</span>

          <div id="kind-picker" class="grid grid-cols-3 gap-2.5">
            <button
              :for={{k, label, desc} <- @kinds}
              type="button"
              id={"kind-#{k}"}
              phx-click="kind"
              phx-value-kind={k}
              class={[
                "text-left flex flex-col gap-1 p-3.5 rounded-xl transition",
                if(@kind == k,
                  do: "bg-hov shadow-[inset_0_0_0_1px_#5a5962]",
                  else: "bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] hover:bg-raised"
                )
              ]}
            >
              <span class="text-[14px] font-semibold">{label}</span>
              <span class="text-[12.5px] text-muted leading-snug text-pretty">{desc}</span>
            </button>
          </div>

          <.form for={@form} id="project-form" phx-change="validate" phx-submit="create">
            <input type="hidden" name="project[kind]" value={@kind} />
            <.input
              field={@form[:name]}
              label="Name"
              placeholder={placeholder(@kind)}
              autocomplete="off"
              phx-debounce="150"
              required
            />

            <%= if @kind == "code" do %>
              <.input
                field={@form[:source]}
                label="Git URL or a folder on the server (optional)"
                placeholder="https://github.com/org/repo  ·  /srv/repos/app  ·  blank for a new repo"
                autocomplete="off"
                phx-debounce="150"
              />
              <div :if={github?(@form.params)} id="github-token-field" class="-mt-1.5">
                <.input
                  field={@form[:github_token]}
                  type="password"
                  label="GitHub token (optional)"
                  placeholder="github_pat_…"
                  autocomplete="off"
                />
                <p class="-mt-2 mb-4 text-[12.5px] text-muted leading-snug text-pretty">
                  Needed for a private repo, and for sessions to push and open PRs. Make a
                  <a
                    href="https://github.com/settings/personal-access-tokens/new"
                    target="_blank"
                    rel="noopener"
                    class="text-soft underline underline-offset-2 hover:text-fg"
                  >fine-grained token</a>
                  for just this repo, with Contents and Pull requests set to read and write.
                  Sessions can read it.
                </p>
              </div>
              <div
                :if={@known_repos != []}
                id="known-repos"
                class="-mt-1.5 mb-4 flex flex-col gap-1.5"
              >
                <span class="text-[12.5px] text-muted">Already on the server</span>
                <div class="flex flex-wrap gap-1.5">
                  <button
                    :for={path <- @known_repos}
                    type="button"
                    phx-click="pick_repo"
                    phx-value-path={path}
                    title={path}
                    class={[
                      "h-8 px-3 rounded-lg text-[13px] transition",
                      if(@form.params["source"] == path,
                        do: "bg-fg text-canvas",
                        else: "bg-raised text-soft hover:bg-hov"
                      )
                    ]}
                  >
                    {Path.basename(path)}
                  </button>
                </div>
              </div>
              <.input
                field={@form[:always_worktree]}
                type="checkbox"
                label="Always start sessions in a new worktree"
              />
            <% end %>

            <div
              :if={@kind == "routine" and @known_routines != []}
              id="known-routines"
              class="-mt-1.5 mb-4 flex flex-col gap-1.5"
            >
              <span class="text-[12.5px] text-muted">Already on the server</span>
              <div class="flex flex-wrap gap-1.5">
                <button
                  :for={name <- @known_routines}
                  type="button"
                  id={"known-routine-#{name}"}
                  phx-click="pick_routine"
                  phx-value-name={name}
                  class={[
                    "h-8 px-3 rounded-lg text-[13px] transition",
                    if(importing?(@form.params) and @form.params["name"] == name,
                      do: "bg-fg text-canvas",
                      else: "bg-raised text-soft hover:bg-hov"
                    )
                  ]}
                >
                  {name}
                </button>
              </div>
            </div>
            <input type="hidden" name="project[import]" value={@form.params["import"] || "false"} />

            <%= if @kind == "routine" and not importing?(@form.params) do %>
              <.input
                field={@form[:description]}
                type="textarea"
                label="What should it do?"
                rows="4"
                placeholder="Read our Front inboxes and give me a short summary each morning: what's urgent, what's waiting on us, and anything that looks like a refund request."
              />
              <div class="fieldset">
                <span class="label">Connectors it may use</span>
                <div id="connector-picks" class="flex flex-wrap gap-2">
                  <label
                    :for={c <- @connectors}
                    class="h-8 flex items-center gap-2 px-3 rounded-lg bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] text-[13px] cursor-pointer has-checked:bg-hov has-checked:shadow-[inset_0_0_0_1px_#5a5962]"
                  >
                    <input type="hidden" name={"project[connectors][#{c.name}]"} value="false" />
                    <input
                      type="checkbox"
                      class="checkbox"
                      name={"project[connectors][#{c.name}]"}
                      value="true"
                      checked={get_in(@form.params, ["connectors", c.name]) == "true"}
                    />
                    {c.name}
                    <span :if={!Connectors.ready?(c, @secrets)} class="text-wait text-[11.5px]">
                      secret not set
                    </span>
                  </label>
                  <span :if={@connectors == []} class="text-[13px] text-faint">
                    No connectors yet. An admin sets them up in the setup project.
                  </span>
                </div>
              </div>
            <% end %>

            <div class="fieldset">
              <span class="label">Who can see it</span>
              <div class="flex gap-2">
                <label
                  :for={{v, l} <- [{"team", "Team"}, {"private", "Only me"}]}
                  class="h-8 flex items-center gap-2 px-3 rounded-lg bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] text-[13px] cursor-pointer has-checked:bg-fg has-checked:text-canvas transition"
                >
                  <input
                    type="radio"
                    name="project[scope]"
                    value={v}
                    checked={@form.params["scope"] == v}
                    class="sr-only"
                  />
                  {l}
                </label>
              </div>
            </div>

            <div
              :if={@form.params["name"] not in [nil, ""]}
              class="mt-2 p-4 rounded-xl bg-code shadow-[inset_0_0_0_1px_var(--color-line)]"
            >
              <span class="text-faint text-[12px] block mb-1.5">Will create</span>
              <pre
                id="will-create"
                class="font-mono text-[12.5px] leading-relaxed text-soft"
                phx-no-format
              >{will_create(@kind, @form.params)}</pre>
            </div>

            <p :if={@error} id="create-error" class="mt-4 text-[13px] text-del">{@error}</p>

            <div class="flex items-center gap-2 mt-6">
              <span class="text-[12.5px] text-faint">You can edit everything after, in the project or in a session.</span>
              <.link navigate={~p"/"} class="btn ml-auto" id="cancel-new-project">Cancel</.link>
              <button type="submit" class="btn btn-primary" id="create-project" disabled={@creating}>
                <.icon :if={@creating} name="hero-arrow-path" class="size-4 animate-spin" />
                {cond do
                  @kind == "routine" and importing?(@form.params) -> "Add"
                  @kind == "routine" -> "Create and draft"
                  true -> "Create"
                end}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp placeholder("code"), do: "amino-monorepo"
  defp placeholder("routine"), do: "front-digest"
  defp placeholder(_), do: "chat"

  defp will_create("routine", %{"name" => name, "import" => "true"}) do
    "routines/#{name}/   existing folder, files kept as they are"
  end

  defp will_create("routine", %{"name" => name}) do
    skill = skill_name(name)

    """
    routines/#{name}/
      AGENTS.md                   drafted from your description
      .opencode/skill/#{skill}/SKILL.md
      opencode.json               gateway connectors · permissions
      schedules.json\
    """
  end

  defp will_create("code", %{"name" => name} = p) do
    source = String.trim(p["source"] || "")

    cond do
      String.starts_with?(source, "/") ->
        "#{source}   (existing folder)"

      String.trim(p["github_token"] || "") != "" and github?(p) ->
        {:ok, repo} = GitTokens.parse_github(source)
        "code/#{name}/   git clone #{GitTokens.https_url(repo)}  (with your token)"

      source != "" ->
        "code/#{name}/   git clone #{source}"

      true ->
        "code/#{name}/   new git repo"
    end
  end

  defp will_create(_, %{"name" => name}), do: "#{name}/\n  AGENTS.md\n  artifacts/"
end
