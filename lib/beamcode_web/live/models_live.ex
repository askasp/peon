defmodule BeamcodeWeb.ModelsLive do
  @moduledoc """
  Model providers on the OpenCode server: which are signed in, and signing in
  to more with an API key or OAuth. Credentials belong to the server, so one
  sign-in serves every user and session.
  """
  use BeamcodeWeb, :live_view
  alias Beamcode.Opencode
  alias BeamcodeWeb.Shell

  # Shown first when connecting. OpenCode Go is the team's subscription.
  @featured ~w(opencode-go opencode openai anthropic deepseek github-copilot)
  @poll_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Models", loading: true, error: nil)
     |> assign(integrations: [], models: %{}, default_model: nil)
     |> assign(query: "", selected: nil, attempt: nil, busy: false, connect_error: nil)
     |> assign_answers(%{})
     |> load()}
  end

  defp load(socket) do
    start_async(socket, :load, fn ->
      with {:ok, integrations} <- Opencode.integrations() do
        models =
          case Opencode.models() do
            {:ok, list} when is_list(list) -> Enum.group_by(list, & &1["providerID"])
            _ -> %{}
          end

        default =
          case Opencode.default_model() do
            {:ok, %{"providerID" => p, "id" => id}} -> "#{p}/#{id}"
            {:ok, %{"providerID" => p, "modelID" => id}} -> "#{p}/#{id}"
            _ -> nil
          end

        {:ok, integrations, models, default}
      end
    end)
  end

  defp assign_answers(socket, answers),
    do: assign(socket, answers: answers, form: to_form(answers, as: :connect))

  @impl true
  def handle_async(:load, {:ok, {:ok, integrations, models, default}}, socket) do
    {:noreply,
     assign(socket,
       loading: false,
       error: nil,
       integrations: Enum.sort_by(integrations, &String.downcase(&1["name"] || &1["id"])),
       models: models,
       default_model: default
     )}
  end

  def handle_async(:load, {:ok, error}, socket),
    do: {:noreply, assign(socket, loading: false, error: Shell.format_error(error))}

  def handle_async(:load, {:exit, reason}, socket),
    do: {:noreply, assign(socket, loading: false, error: inspect(reason))}

  def handle_async(:connect, {:ok, result}, socket) do
    socket = assign(socket, busy: false)

    case result do
      {:ok, %{"attemptID" => _} = attempt} ->
        Process.send_after(self(), :poll, @poll_ms)

        {:noreply,
         assign(socket, attempt: Map.put(attempt, "integration", socket.assigns.selected))}

      {:ok, _} ->
        {:noreply, connected(socket)}

      error ->
        {:noreply, assign(socket, connect_error: Shell.format_error(error))}
    end
  end

  def handle_async(:connect, {:exit, reason}, socket),
    do: {:noreply, assign(socket, busy: false, connect_error: inspect(reason))}

  # The listener took the code; the next status poll sees the sign-in complete.
  def handle_async(:callback, {:ok, :ok}, socket) do
    send(self(), :poll)
    {:noreply, assign(socket, busy: false)}
  end

  def handle_async(:callback, {:ok, error}, socket),
    do: {:noreply, assign(socket, busy: false, connect_error: Shell.format_error(error))}

  def handle_async(:callback, {:exit, reason}, socket),
    do: {:noreply, assign(socket, busy: false, connect_error: inspect(reason))}

  def handle_async(:poll, {:ok, result}, socket) do
    case {socket.assigns.attempt, result} do
      {nil, _} ->
        {:noreply, socket}

      {_, {:ok, %{"status" => "complete"}}} ->
        {:noreply, connected(socket)}

      {_, {:ok, %{"status" => "failed"} = s}} ->
        {:noreply, assign(socket, attempt: nil, connect_error: s["message"] || "Sign-in failed.")}

      {_, {:ok, %{"status" => "expired"}}} ->
        {:noreply,
         assign(socket, attempt: nil, connect_error: "The sign-in expired. Start again.")}

      _ ->
        Process.send_after(self(), :poll, @poll_ms)
        {:noreply, socket}
    end
  end

  def handle_async(:poll, _, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, socket}
  end

  defp connected(socket) do
    name = integration_name(socket.assigns, socket.assigns.selected)

    socket
    |> assign(selected: nil, attempt: nil, connect_error: nil)
    |> assign_answers(%{})
    |> put_flash(:info, "#{name} is connected. Its models are in every session's model picker.")
    |> load()
  end

  @impl true
  def handle_info(:poll, %{assigns: %{attempt: %{} = a}} = socket) do
    {:noreply,
     start_async(socket, :poll, fn -> Opencode.oauth_status(a["integration"], a["attemptID"]) end)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, query: q)}

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> cancel_attempt()
     |> assign(selected: id, connect_error: nil)
     |> assign_answers(%{})}
  end

  def handle_event("back", _params, socket) do
    {:noreply, socket |> cancel_attempt() |> assign(selected: nil, connect_error: nil)}
  end

  def handle_event("change", %{"connect" => params}, socket),
    do: {:noreply, assign_answers(socket, Map.merge(socket.assigns.answers, params))}

  def handle_event("connect_key", %{"connect" => params}, socket) do
    answers = Map.merge(socket.assigns.answers, params)
    id = socket.assigns.selected
    method = Enum.find(methods(socket.assigns, id), &(&1["type"] == "key"))
    key = String.trim(answers["key"] || "")

    if key == "" do
      {:noreply, assign(socket, connect_error: "Paste the API key.")}
    else
      answer = answer(method, answers)

      {:noreply,
       socket
       |> assign_answers(answers)
       |> assign(busy: true, connect_error: nil)
       |> start_async(:connect, fn -> Opencode.connect_key(id, key, answer) end)}
    end
  end

  def handle_event("connect_oauth", %{"method" => method_id} = params, socket) do
    answers = Map.merge(socket.assigns.answers, params["connect"] || %{})
    id = socket.assigns.selected
    method = Enum.find(methods(socket.assigns, id), &(&1["id"] == method_id))
    answer = answer(method, answers)

    {:noreply,
     socket
     |> assign_answers(answers)
     |> assign(busy: true, connect_error: nil)
     |> start_async(:connect, fn -> Opencode.start_oauth(id, method_id, answer) end)}
  end

  def handle_event("complete_oauth", %{"code" => code}, socket) do
    a = socket.assigns.attempt

    case Opencode.complete_oauth(a["integration"], a["attemptID"], String.trim(code)) do
      {:ok, _} -> {:noreply, connected(socket)}
      error -> {:noreply, assign(socket, connect_error: Shell.format_error(error))}
    end
  end

  def handle_event("paste_callback", %{"url" => url}, socket) do
    {:noreply,
     socket
     |> assign(busy: true, connect_error: nil)
     |> start_async(:callback, fn -> Opencode.forward_oauth_callback(url) end)}
  end

  def handle_event("cancel_oauth", _params, socket),
    do: {:noreply, socket |> cancel_attempt() |> assign(connect_error: nil)}

  def handle_event("disconnect", %{"id" => credential_id}, socket) do
    case Opencode.remove_credential(credential_id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Disconnected.") |> load()}

      error ->
        {:noreply,
         put_flash(socket, :error, "Could not disconnect: #{Shell.format_error(error)}")}
    end
  end

  defp cancel_attempt(%{assigns: %{attempt: %{} = a}} = socket) do
    Opencode.cancel_oauth(a["integration"], a["attemptID"])
    assign(socket, attempt: nil)
  end

  defp cancel_attempt(socket), do: socket

  ## Integrations and their forms

  defp find(assigns, id), do: Enum.find(assigns.integrations, &(&1["id"] == id))

  defp integration_name(assigns, id), do: (find(assigns, id) || %{})["name"] || id

  defp methods(assigns, id), do: (find(assigns, id) || %{})["methods"] || []

  defp signed_in?(i), do: (i["connections"] || []) != []

  defp featured(integrations) do
    by_id = Map.new(integrations, &{&1["id"], &1})
    for id <- @featured, i = by_id[id], not signed_in?(i), do: i
  end

  defp matching(integrations, query) do
    q = query |> String.trim() |> String.downcase()

    if q == "" do
      []
    else
      integrations
      |> Enum.reject(&signed_in?/1)
      |> Enum.filter(fn i ->
        String.contains?(String.downcase(i["name"] || ""), q) or String.contains?(i["id"], q)
      end)
      |> Enum.take(12)
    end
  end

  # The fields a method asks for: hidden ones go with their default; `when`
  # shows a field only for some answers to another.
  defp fields(method), do: Enum.reject(method["form"] || [], &(&1["type"] == "external"))

  defp shown?(field, answers) do
    not Map.get(field, "hidden", false) and
      Enum.all?(field["when"] || [], fn w ->
        value = Map.get(answers, w["key"])

        case w["op"] do
          "eq" -> to_string(value) == to_string(w["value"])
          "neq" -> to_string(value) != to_string(w["value"])
          _ -> true
        end
      end)
  end

  defp answer(nil, _answers), do: nil

  defp answer(method, answers) do
    case fields(method) do
      [] ->
        nil

      fields ->
        for f <- fields,
            hidden = Map.get(f, "hidden", false),
            hidden or shown?(f, answers),
            value = if(hidden, do: f["default"], else: Map.get(answers, f["key"], f["default"])),
            value not in [nil, ""],
            into: %{},
            do: {f["key"], cast(f["type"], value)}
    end
  end

  defp cast("boolean", v), do: v in [true, "true"]

  defp cast(type, v) when type in ["number", "integer"] and is_binary(v) do
    case Float.parse(v) do
      {n, _} -> if type == "integer", do: trunc(n), else: n
      :error -> v
    end
  end

  defp cast(_type, v), do: v

  defp model_names(models, id), do: (models[id] || []) |> Enum.map(&(&1["name"] || &1["id"]))

  defp connection_label(%{"type" => "env"} = c), do: "from $#{c["name"]} on the server"
  defp connection_label(%{"method" => "oauth"} = c), do: "signed in · #{c["label"]}"
  defp connection_label(c), do: "API key · #{c["label"]}"

  @impl true
  def render(assigns) do
    connected = Enum.filter(assigns.integrations, &signed_in?/1)

    assigns =
      assign(assigns, connected: connected, selected_info: find(assigns, assigns.selected))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={:models}>
      <Layouts.page_header
        title="Models"
        subtitle="Sign-ins on the OpenCode server, shared by every user and session"
      />

      <div class="flex-1 min-h-0 overflow-y-auto">
        <div class="max-w-[1100px] px-10 py-6 flex gap-8 items-start">
          <div class="flex-1 min-w-0 flex flex-col gap-4" id="connected-providers">
            <div :if={@loading} class="text-[13px] text-faint">Loading…</div>
            <p :if={@error} id="models-error" class="text-[13px] text-del">
              Can't reach the OpenCode server: {@error}
            </p>

            <div
              :if={@default_model}
              class="flex items-center gap-2 text-[13px] text-muted"
              id="default-model"
            >
              Default model <span class="font-mono text-[12.5px] text-soft">{@default_model}</span>
              <span class="text-faint">· set in the server's opencode.json</span>
            </div>

            <div
              :if={!@loading and !@error and @connected == []}
              id="providers-empty"
              class="rounded-[14px] bg-panel p-6 text-[13.5px] text-muted leading-relaxed"
            >
              No provider is signed in yet, so sessions only have the models in the server's own config.
              Connect one on the right; <span class="text-fg">OpenCode Go</span>
              takes the API key from your opencode.ai account.
            </div>

            <div
              :for={i <- @connected}
              id={"provider-#{i["id"]}"}
              class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5 flex flex-col gap-3"
            >
              <div class="flex items-center gap-2">
                <span class="size-2 rounded-full bg-add"></span>
                <span class="text-[15px] font-semibold">{i["name"]}</span>
                <span class="font-mono text-[12px] text-faint">{i["id"]}</span>
                <span class="ml-auto text-[12.5px] text-muted">
                  {length(model_names(@models, i["id"]))} models
                </span>
              </div>

              <div
                :for={c <- i["connections"]}
                class="flex items-center gap-2 h-9 px-3 rounded-lg bg-code text-[13px]"
              >
                <span class="text-soft truncate">{connection_label(c)}</span>
                <span
                  :if={c["status"]}
                  class="text-[12px] text-wait truncate"
                  title={c["status"]["message"]}
                >
                  needs sign-in again
                </span>
                <button
                  :if={c["type"] == "credential"}
                  type="button"
                  class="ml-auto text-[12.5px] text-faint hover:text-del transition"
                  phx-click="disconnect"
                  phx-value-id={c["id"]}
                  data-confirm={"Disconnect #{i["name"]}? Sessions using its models will stop working."}
                  id={"disconnect-#{c["id"]}"}
                >
                  Disconnect
                </button>
              </div>

              <div :if={model_names(@models, i["id"]) != []} class="flex flex-wrap gap-1.5">
                <span
                  :for={name <- Enum.take(model_names(@models, i["id"]), 10)}
                  class="h-6 px-2 flex items-center rounded-md bg-raised text-[12px] text-soft"
                >
                  {name}
                </span>
                <span
                  :if={length(model_names(@models, i["id"])) > 10}
                  class="h-6 px-2 flex items-center text-[12px] text-faint"
                >
                  +{length(model_names(@models, i["id"])) - 10} more
                </span>
              </div>
            </div>
          </div>

          <div class="w-[360px] flex-none flex flex-col gap-3" id="connect-panel">
            <div class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5">
              <%= if @selected_info do %>
                {connect_form(assigns)}
              <% else %>
                <span class="block text-[14.5px] font-semibold mb-1">Connect a provider</span>
                <span class="block text-[12.5px] text-muted mb-4">
                  One sign-in for the whole team. Sessions can read nothing of it.
                </span>
                <div class="flex flex-col gap-1.5" id="featured-providers">
                  <button
                    :for={i <- featured(@integrations)}
                    type="button"
                    phx-click="select"
                    phx-value-id={i["id"]}
                    id={"pick-#{i["id"]}"}
                    class="group h-10 flex items-center gap-2 px-3 rounded-lg bg-raised hover:bg-hov text-[13.5px] text-left transition"
                  >
                    {i["name"]}
                    <span :if={i["id"] == "opencode-go"} class="text-[11.5px] text-run">
                      team subscription
                    </span>
                    <.icon
                      name="hero-chevron-right-micro"
                      class="size-4 ml-auto text-faint group-hover:text-fg group-hover:translate-x-0.5 transition"
                    />
                  </button>
                </div>
                <form phx-change="search" phx-submit="search" id="provider-search" class="mt-4">
                  <input
                    name="q"
                    value={@query}
                    placeholder={"Search all #{length(@integrations)} providers"}
                    autocomplete="off"
                    phx-debounce="100"
                    class="w-full input h-9 text-[13px]"
                    id="provider-search-input"
                    data-kb-search
                  />
                </form>
                <div class="flex flex-col mt-1.5" id="provider-results">
                  <button
                    :for={i <- matching(@integrations, @query)}
                    type="button"
                    phx-click="select"
                    phx-value-id={i["id"]}
                    id={"result-#{i["id"]}"}
                    class="h-8 flex items-center gap-2 px-2 rounded-md hover:bg-raised text-[13px] text-left transition"
                  >
                    {i["name"]} <span class="font-mono text-[11.5px] text-faint">{i["id"]}</span>
                  </button>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp connect_form(assigns) do
    methods = assigns.selected_info["methods"] || []

    assigns =
      assign(assigns,
        key_method: Enum.find(methods, &(&1["type"] == "key")),
        oauth_methods: Enum.filter(methods, &(&1["type"] == "oauth")),
        env: Enum.find(methods, &(&1["type"] == "env"))
      )

    ~H"""
    <div class="flex items-center gap-2 mb-4">
      <button
        type="button"
        phx-click="back"
        id="connect-back"
        class="size-7 -ml-1.5 flex items-center justify-center rounded-md text-muted hover:text-fg hover:bg-raised transition"
      >
        <.icon name="hero-chevron-left-micro" class="size-4" />
      </button>
      <span class="text-[14.5px] font-semibold">{@selected_info["name"]}</span>
    </div>

    <%= if @attempt do %>
      <div id="oauth-attempt" class="flex flex-col gap-3">
        <p class="text-[13px] text-soft leading-relaxed whitespace-pre-line">
          {@attempt["instructions"]}
        </p>
        <a
          href={@attempt["url"]}
          target="_blank"
          rel="noopener"
          class="btn btn-primary w-full"
          id="oauth-open"
        >
          Open sign-in page <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
        </a>
        <%= if @attempt["mode"] == "code" do %>
          <form phx-submit="complete_oauth" id="oauth-code-form" class="flex gap-2">
            <input
              name="code"
              placeholder="Paste the code"
              autocomplete="off"
              class="input flex-1 h-9 font-mono text-[12.5px]"
              id="oauth-code"
            />
            <button type="submit" class="btn" id="oauth-complete">Finish</button>
          </form>
        <% else %>
          <div class="flex items-center gap-2 text-[12.5px] text-muted">
            <.icon name="hero-arrow-path" class="size-3.5 animate-spin" />
            Waiting for you to finish signing in…
          </div>
          <form
            phx-submit="paste_callback"
            id="oauth-callback-form"
            class="flex flex-col gap-2 pt-3 border-t border-line"
          >
            <label for="oauth-callback" class="text-[12.5px] text-muted leading-snug text-pretty">
              Browser ended on a <span class="font-mono text-soft">127.0.0.1</span>
              page that won't load? That address is on the OpenCode server, not your machine.
              Copy it from the address bar and paste it here.
            </label>
            <div class="flex gap-2">
              <input
                name="url"
                placeholder="http://127.0.0.1:…/auth/callback?code=…"
                autocomplete="off"
                spellcheck="false"
                class="input flex-1 h-9 font-mono text-[12px]"
                id="oauth-callback"
              />
              <button type="submit" class="btn" id="oauth-callback-submit" disabled={@busy}>
                <.icon :if={@busy} name="hero-arrow-path" class="size-4 animate-spin" /> Finish
              </button>
            </div>
          </form>
        <% end %>
        <button
          type="button"
          phx-click="cancel_oauth"
          id="oauth-cancel"
          class="text-[12.5px] text-faint hover:text-fg self-start"
        >
          Cancel
        </button>
      </div>
    <% else %>
      <div class="flex flex-col gap-5">
        <.form
          :if={@key_method}
          for={@form}
          id="connect-key-form"
          phx-change="change"
          phx-submit="connect_key"
        >
          {method_fields(Map.merge(assigns, %{method: @key_method, prefix: "key"}))}
          <.input
            field={@form[:key]}
            id="connect-key"
            type="password"
            label={@key_method["label"] || "API key"}
            autocomplete="off"
          />
          <button
            type="submit"
            class="btn btn-primary w-full"
            id="connect-key-submit"
            disabled={@busy}
          >
            <.icon :if={@busy} name="hero-arrow-path" class="size-4 animate-spin" /> Connect
          </button>
        </.form>

        <.form
          :for={m <- @oauth_methods}
          for={@form}
          id={"connect-oauth-#{m["id"]}"}
          phx-change="change"
          phx-submit="connect_oauth"
          class={["flex flex-col", @key_method && "pt-4 border-t border-line"]}
        >
          <input type="hidden" name="method" value={m["id"]} />
          {method_fields(Map.merge(assigns, %{method: m, prefix: m["id"]}))}
          <button
            type="submit"
            class="btn w-full"
            id={"connect-oauth-#{m["id"]}-submit"}
            disabled={@busy}
          >
            {m["label"]}
          </button>
        </.form>

        <p :if={@env} class="text-[12.5px] text-faint leading-snug">
          Or set <span class="font-mono">{Enum.join(@env["names"], " / ")}</span>
          in the OpenCode server's environment.
        </p>
      </div>
    <% end %>

    <p :if={@connect_error} id="connect-error" class="mt-3 text-[13px] text-del">{@connect_error}</p>
    """
  end

  defp method_fields(assigns) do
    ~H"""
    <%= for f <- fields(@method), shown?(f, @answers) do %>
      <%= cond do %>
        <% f["type"] == "boolean" -> %>
          <.input
            field={@form[f["key"]]}
            id={"#{@prefix}-#{f["key"]}"}
            type="checkbox"
            label={f["title"] || f["key"]}
          />
        <% f["options"] -> %>
          <.input
            field={@form[f["key"]]}
            id={"#{@prefix}-#{f["key"]}"}
            type="select"
            label={f["title"] || f["key"]}
            prompt="Choose…"
            options={Enum.map(f["options"], &{&1["label"], &1["value"]})}
          />
        <% true -> %>
          <.input
            field={@form[f["key"]]}
            id={"#{@prefix}-#{f["key"]}"}
            label={f["title"] || f["key"]}
            placeholder={f["placeholder"]}
            autocomplete="off"
          />
      <% end %>
    <% end %>
    """
  end
end
