defmodule BeamcodeWeb.UserAuth do
  @moduledoc "Session-cookie login. `current_scope` is `%{user: user}`."
  use BeamcodeWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias Beamcode.Accounts

  def log_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, "users:#{user.id}")
    |> redirect(to: ~p"/")
  end

  def log_out(conn) do
    if id = get_session(conn, :live_socket_id),
      do: BeamcodeWeb.Endpoint.broadcast(id, "disconnect", %{})

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  def fetch_current_scope(conn, _opts) do
    user = (id = get_session(conn, :user_id)) && Accounts.get_user(id)
    assign(conn, :current_scope, user && %{user: user})
  end

  def require_user(conn, _opts) do
    if conn.assigns.current_scope do
      conn
    else
      conn |> redirect(to: ~p"/login") |> halt()
    end
  end

  def redirect_if_user(conn, _opts) do
    if conn.assigns.current_scope, do: conn |> redirect(to: ~p"/") |> halt(), else: conn
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    user = (id = session["user_id"]) && Accounts.get_user(id)

    if user do
      {:cont, Phoenix.Component.assign(socket, :current_scope, %{user: user})}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  def on_mount(:require_admin, _params, _session, socket) do
    if socket.assigns.current_scope.user.admin do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Admins only.")
       |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end
end
