defmodule BeamcodeWeb.ConnectorsLive do
  @moduledoc """
  Connectors (files in setup/connectors/) and the vault. Admins set secrets
  here; sessions in the setup project write the files.
  """
  use BeamcodeWeb, :live_view
  alias Beamcode.{Connectors, Vault, Workspace}
  alias BeamcodeWeb.Shell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Connectors", connectors: [], secrets: [], loading: true)
     |> assign(secret_form: to_form(%{"name" => "", "value" => ""}, as: :secret))
     |> load()}
  end

  defp load(socket) do
    # GitHub tokens are managed in each code project's settings.
    start_async(socket, :load, fn ->
      {Connectors.list(),
       Enum.reject(Vault.list(), &String.starts_with?(&1.name, "GITHUB_TOKEN_"))}
    end)
  end

  @impl true
  def handle_async(:load, {:ok, {connectors, secrets}}, socket) do
    {:noreply, assign(socket, connectors: connectors, secrets: secrets, loading: false)}
  end

  def handle_async(:load, _, socket), do: {:noreply, assign(socket, loading: false)}

  def handle_async(:sync, _, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("save_secret", %{"secret" => %{"name" => name, "value" => value}}, socket) do
    user = socket.assigns.current_scope.user

    case Vault.put(String.trim(name), value, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{name} saved to the vault.")
         |> assign(secret_form: to_form(%{"name" => "", "value" => ""}, as: :secret))
         |> start_async(:sync, fn -> Connectors.sync_all() end)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Secret names are UPPER_SNAKE_CASE and the value can't be empty."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save the secret.")}
    end
  end

  def handle_event("pick_secret", %{"name" => name}, socket) do
    {:noreply,
     assign(socket, secret_form: to_form(%{"name" => name, "value" => ""}, as: :secret))}
  end

  def handle_event("delete_secret", %{"name" => name}, socket) do
    Vault.delete(name)

    {:noreply,
     socket
     |> put_flash(:info, "#{name} removed.")
     |> start_async(:sync, fn -> Connectors.sync_all() end)}
  end

  def handle_event("apply", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Applied to projects.")
     |> start_async(:sync, fn -> Connectors.sync_all() end)}
  end

  def handle_event("new_connector", _params, socket) do
    case Workspace.setup_project() do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The setup project isn't ready. Is the OpenCode server reachable?"
         )}

      setup ->
        {:noreply, Shell.new_session(socket, setup, worktree: false)}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :secret_names, MapSet.new(assigns.secrets, & &1.name))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={:connectors}>
      <Layouts.page_header
        title="Connectors"
        subtitle="Files in setup/connectors/, secrets in the vault"
      >
        <:actions>
          <button class="btn" phx-click="apply" id="apply-connectors">Apply to projects</button>
          <button class="btn btn-primary" phx-click="new_connector" id="new-connector">Set up a connector</button>
        </:actions>
      </Layouts.page_header>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <div class="max-w-[1100px] px-10 py-6 flex gap-8">
          <div class="flex-1 min-w-0 flex flex-col gap-4" id="connector-list">
            <div :if={@loading} class="text-[13px] text-faint">Loading…</div>
            <div
              :if={!@loading and @connectors == []}
              class="rounded-[14px] bg-panel p-6 text-[13.5px] text-muted leading-relaxed"
              id="connectors-empty"
            >
              No connectors yet. Press <span class="text-fg">Set up a connector</span>: a session in the setup project
              reads the API docs, writes <span class="font-mono text-[12.5px]">connectors/&lt;name&gt;.json</span>, and asks you to put the token here.
            </div>

            <div
              :for={c <- @connectors}
              id={"connector-#{c.name}"}
              class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5 flex flex-col gap-3"
            >
              <div class="flex items-center gap-2">
                <span class="text-[15px] font-semibold">{c.name}</span>
                <span class="font-mono text-[12px] text-faint">setup/connectors/{c.file}</span>
                <span :if={c.error} class="ml-auto text-[12px] text-del">invalid</span>
                <span
                  :if={!c.error and Connectors.ready?(c, @secret_names)}
                  class="ml-auto text-[12px] text-add"
                >ready</span>
                <span
                  :if={!c.error and !Connectors.ready?(c, @secret_names)}
                  class="ml-auto text-[12px] text-wait"
                >secret not set</span>
              </div>
              <p :if={c.error} class="text-[13px] text-del">{c.error}</p>

              <%= if !c.error do %>
                <div class="text-[12.5px] text-muted font-mono truncate">{c.base_url}</div>
                <div class="rounded-[10px] bg-code overflow-hidden">
                  <div
                    :for={t <- c.tools}
                    class="flex items-center gap-3 px-3.5 h-8 font-mono text-[12px] border-b border-line last:border-0"
                  >
                    <span class="w-[190px] truncate text-soft">{t.name}</span>
                    <span class="w-[50px] text-muted">{t.method}</span>
                    <span class="flex-1 truncate text-muted">{t.path}</span>
                    <span class={[
                      "w-[42px] text-right",
                      t.permission == "allow" && "text-add",
                      t.permission == "ask" && "text-wait",
                      t.permission == "deny" && "text-del"
                    ]}>{t.permission}</span>
                  </div>
                </div>
                <div class="grid grid-cols-[90px_1fr] gap-y-1.5 text-[13px]">
                  <span class="text-muted">Vault</span>
                  <span>
                    <%= cond do %>
                      <% c.secret == nil -> %>
                        <span class="text-faint">no secret needed</span>
                      <% MapSet.member?(@secret_names, c.secret) -> %>
                        <span class="font-mono text-[12.5px]">{c.secret}</span>
                        <span class="text-faint">· {Vault.hint(c.secret)}</span>
                      <% true -> %>
                        <button
                          class="text-wait hover:underline"
                          phx-click="pick_secret"
                          phx-value-name={c.secret}
                          id={"set-secret-#{c.name}"}
                        >
                          Set {c.secret}
                        </button>
                    <% end %>
                  </span>
                  <span class="text-muted">Granted</span>
                  <span>{if c.projects == [], do: "no projects yet", else: Enum.join(c.projects, ", ")}</span>
                </div>
              <% end %>
            </div>
          </div>

          <div class="w-[340px] flex-none flex flex-col gap-4">
            <.form
              for={@secret_form}
              id="secret-form"
              phx-submit="save_secret"
              class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5"
            >
              <span class="block text-[14.5px] font-semibold mb-1">Vault</span>
              <span class="block text-[12.5px] text-muted mb-4">
                Secrets are encrypted and only used by the gateway when a connector calls its API. They never reach a session or a file.
              </span>
              <.input
                field={@secret_form[:name]}
                label="Name"
                placeholder="FRONT_TOKEN"
                autocomplete="off"
                class="input font-mono"
              />
              <.input
                field={@secret_form[:value]}
                type="password"
                label="Value"
                autocomplete="new-password"
              />
              <button type="submit" class="btn btn-primary w-full" id="save-secret">Save to vault</button>
            </.form>

            <div class="flex flex-col gap-1" id="secret-list">
              <div
                :for={s <- @secrets}
                class="h-10 flex items-center gap-2 px-3 rounded-lg bg-panel text-[13px]"
              >
                <span class="font-mono text-[12.5px] truncate">{s.name}</span>
                <span class="text-[12px] text-faint truncate">· {s.set_by && s.set_by.username} · {Calendar.strftime(
                  s.updated_at,
                  "%-d %b"
                )}</span>
                <button
                  class="ml-auto text-faint hover:text-del"
                  phx-click="delete_secret"
                  phx-value-name={s.name}
                  data-confirm={"Remove #{s.name}?"}
                  id={"delete-secret-#{s.name}"}
                >
                  <.icon name="hero-trash-micro" class="size-3.5" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
