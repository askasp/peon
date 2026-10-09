defmodule BeamcodeWeb.UsersLive do
  @moduledoc "Admins create users with a username and password."
  use BeamcodeWeb, :live_view
  alias Beamcode.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Users")
     |> assign(form: to_form(Accounts.change_user()))
     |> stream(:users, Accounts.list_users())}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply,
     assign(socket,
       form: to_form(Accounts.change_user(%Accounts.User{}, params), action: :validate)
     )}
  end

  def handle_event("create", %{"user" => params}, socket) do
    case Accounts.create_user(params, admin: params["admin"] == "true") do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user.username} can sign in now.")
         |> assign(form: to_form(Accounts.change_user()))
         |> stream_insert(:users, user)}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(cs))}
    end
  end

  def handle_event("toggle_admin", %{"id" => id}, socket) do
    user = Accounts.get_user(id)

    if user.id == socket.assigns.current_scope.user.id do
      {:noreply, put_flash(socket, :error, "You can't change your own admin role.")}
    else
      {:ok, user} = Accounts.set_admin(user, !user.admin)
      {:noreply, stream_insert(socket, :users, user)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user(id)

    if user.id == socket.assigns.current_scope.user.id do
      {:noreply, put_flash(socket, :error, "You can't delete yourself.")}
    else
      {:ok, _} = Accounts.delete_user(user)
      {:noreply, stream_delete(socket, :users, user)}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={:users}>
      <Layouts.page_header title="Users" subtitle="Username and password, created by an admin" />
      <div class="flex-1 min-h-0 overflow-y-auto">
        <div class="max-w-[900px] px-10 py-6 flex gap-8">
          <div id="users" phx-update="stream" class="flex-1 flex flex-col gap-1">
            <div
              :for={{dom_id, u} <- @streams.users}
              id={dom_id}
              class="h-12 flex items-center gap-3 px-3.5 rounded-[10px] bg-panel"
            >
              <Layouts.avatar name={u.username} />
              <span class="text-[14px]">{u.username}</span>
              <span
                :if={u.admin}
                class="text-[11.5px] px-1.5 h-5 flex items-center rounded-md bg-raised text-muted"
              >admin</span>
              <div class="ml-auto flex gap-1.5">
                <button
                  class="btn btn-sm"
                  phx-click="toggle_admin"
                  phx-value-id={u.id}
                  id={"toggle-admin-#{u.id}"}
                >
                  {if u.admin, do: "Remove admin", else: "Make admin"}
                </button>
                <button
                  class="btn btn-sm btn-danger"
                  phx-click="delete"
                  phx-value-id={u.id}
                  data-confirm={"Delete #{u.username}?"}
                  id={"delete-user-#{u.id}"}
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
          <.form
            for={@form}
            id="user-form"
            phx-change="validate"
            phx-submit="create"
            class="w-[300px] flex-none rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-5 self-start"
          >
            <span class="block text-[14.5px] font-semibold mb-4">Add a user</span>
            <.input field={@form[:username]} label="Username" autocomplete="off" />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
            />
            <.input name="user[admin]" type="checkbox" label="Admin" value={false} id="user-admin" />
            <button type="submit" class="btn btn-primary w-full" id="create-user">Create user</button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
