defmodule BeamcodeWeb.UserAuth do
  @moduledoc "Session-cookie login. `current_scope` is `%{user: user}`."
  use BeamcodeWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias Beamcode.Accounts

  def log_in(conn, user) do
    return_to = get_session(conn, :user_return_to) || ~p"/app"

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, "users:#{user.id}")
    |> redirect(to: return_to)
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
      # Back to the page asked for after logging in (e.g. /app).
      conn =
        if conn.method == "GET",
          do: put_session(conn, :user_return_to, current_path(conn)),
          else: conn

      conn |> redirect(to: ~p"/login") |> halt()
    end
  end

  def redirect_if_user(conn, _opts) do
    if conn.assigns.current_scope, do: conn |> redirect(to: ~p"/app") |> halt(), else: conn
  end
end
