defmodule BeamcodeWeb.SettingsLive do
  @moduledoc "Keymap, in-session shortcuts (OpenCode syntax, editable) and password."
  use BeamcodeWeb, :live_view
  alias Beamcode.{Accounts, Keybinds}
  alias BeamcodeWeb.Shell

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(page_title: "Settings")
     |> assign(keys_form: to_form(Keybinds.merged(user), as: :keys))
     |> assign(prefs_form: prefs_form(user))
     |> assign(password_form: to_form(Accounts.change_password(user)))}
  end

  @impl true
  def handle_event("save_keys", %{"keys" => params}, socket),
    do: {:noreply, save_keys(socket, Keybinds.overrides(params))}

  def handle_event("reset_keys", _params, socket), do: {:noreply, save_keys(socket, %{})}

  def handle_event("save_prefs", %{"prefs" => params}, socket) do
    user = socket.assigns.current_scope.user
    stored = Map.merge(Keybinds.overrides(Keybinds.merged(user)), Keybinds.pref_overrides(params))
    {:noreply, socket |> store_keybinds(stored) |> put_flash(:info, "Keymap saved.")}
  end

  def handle_event("save_password", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_password(user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password changed.")
         |> assign(
           current_scope: %{user: user},
           password_form: to_form(Accounts.change_password(user))
         )}

      {:error, cs} ->
        {:noreply, assign(socket, password_form: to_form(cs))}
    end
  end

  defp save_keys(socket, overrides) do
    user = socket.assigns.current_scope.user
    stored = Map.merge(Keybinds.pref_overrides(Keybinds.prefs(user)), overrides)
    socket |> store_keybinds(stored) |> put_flash(:info, "Shortcuts saved.")
  end

  defp store_keybinds(socket, stored) do
    {:ok, user} = Accounts.update_keybinds(socket.assigns.current_scope.user, stored)

    socket
    |> assign(current_scope: %{user: user})
    |> Shell.assign_keybinds(user)
    |> assign(keys_form: to_form(Keybinds.merged(user), as: :keys), prefs_form: prefs_form(user))
  end

  defp prefs_form(user) do
    user |> Keybinds.prefs() |> Map.new(fn {k, v} -> {k, to_string(v)} end) |> to_form(as: :prefs)
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :defaults, Keybinds.defaults())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={:settings}>
      <Layouts.page_header title="Settings" subtitle={@current_scope.user.username} />
      <div class="flex-1 min-h-0 overflow-y-auto">
        <div class="max-w-[1000px] px-10 py-6 flex gap-8 items-start">
          <div class="flex-1 min-w-0 flex flex-col gap-6">
            <.form
              for={@prefs_form}
              id="prefs-form"
              phx-submit="save_prefs"
              class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5"
            >
              <div class="flex items-center mb-1">
                <span class="text-[14.5px] font-semibold">Keymap</span>
                <button
                  type="button"
                  class="ml-auto text-[12.5px] text-muted hover:text-fg"
                  phx-click={JS.dispatch("chatos:kb", detail: %{action: "help"})}
                  id="show-shortcuts"
                >
                  Show all shortcuts
                </button>
              </div>
              <p class="text-[12.5px] text-muted mb-4">
                <span class="font-mono">tmux</span>: press the prefix, then a key (<.kbd k={
                  @kb_prefs["prefix"]
                } /> <span class="font-mono">1</span>
                opens the first project). <span class="font-mono">standard</span>: <.kbd k="alt+1" />,
                <.kbd k="mod+[" /> and <span class="font-mono">g</span>
                chords.
              </p>
              <div class="grid grid-cols-2 gap-x-4">
                <.input
                  field={@prefs_form[:keymap]}
                  type="select"
                  label="Keymap"
                  options={[{"tmux (prefix key)", "tmux"}, {"Standard", "standard"}]}
                />
                <.input
                  field={@prefs_form[:prefix]}
                  type="select"
                  label="Prefix key (tmux)"
                  options={Enum.map(Keybinds.prefixes(), &{key_label(&1, false), &1})}
                />
                <.input
                  field={@prefs_form[:which_key_delay]}
                  type="number"
                  min="0"
                  max="1500"
                  step="50"
                  label="Which-key popup delay (ms)"
                />
              </div>
              <div class="flex gap-6">
                <.input field={@prefs_form[:status_line]} type="checkbox" label="Status line" />
                <.input field={@prefs_form[:keycast]} type="checkbox" label="Show pressed keys" />
              </div>
              <button type="submit" class="btn btn-primary mt-1" id="save-prefs">Save keymap</button>
            </.form>
            <.form
              for={@keys_form}
              id="keys-form"
              phx-submit="save_keys"
              class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5"
            >
              <div class="flex items-center mb-1">
                <span class="text-[14.5px] font-semibold">In-session shortcuts</span>
                <button
                  type="button"
                  class="ml-auto text-[12.5px] text-muted hover:text-fg"
                  phx-click="reset_keys"
                  id="reset-keys"
                >
                  Reset to OpenCode defaults
                </button>
              </div>
              <p class="text-[12.5px] text-muted mb-4">
                Same names and syntax as OpenCode: <span class="font-mono">ctrl+g</span>, <span class="font-mono">&lt;leader&gt;m</span>,
                alternatives separated by commas, <span class="font-mono">none</span>
                to turn one off. <span class="font-mono">&lt;leader&gt;</span>
                is the prefix key (<.kbd k={@kb_prefs["prefix"]} />).
              </p>
              <div class="flex flex-col">
                <div
                  :for={{action, _default, desc} <- Keybinds.list()}
                  class="grid grid-cols-[1fr_220px] items-center gap-4 py-1.5 border-b border-line last:border-0"
                >
                  <div class="flex flex-col min-w-0">
                    <span class="font-mono text-[12.5px]">{action}</span>
                    <span class="text-[12.5px] text-muted truncate">{desc}</span>
                  </div>
                  <input
                    id={"key-#{action}"}
                    name={"keys[#{action}]"}
                    value={@keys_form.params[action]}
                    placeholder={@defaults[action]}
                    autocomplete="off"
                    spellcheck="false"
                    class={[
                      "input h-8 font-mono text-[12.5px]",
                      @keys_form.params[action] != @defaults[action] &&
                        "shadow-[inset_0_0_0_1px_var(--color-run)]"
                    ]}
                  />
                </div>
              </div>
              <button type="submit" class="btn btn-primary mt-4" id="save-keys">Save shortcuts</button>
            </.form>
          </div>

          <.form
            for={@password_form}
            id="password-form"
            phx-submit="save_password"
            class="w-[300px] flex-none rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5"
          >
            <span class="block text-[14.5px] font-semibold mb-4">Password</span>
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
            />
            <button type="submit" class="btn w-full" id="save-password">Change password</button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
