defmodule BeamcodeWeb.UserSocket do
  @moduledoc """
  The phone app's one websocket, `/socket`. Everything travels over it: the app
  asks with channel messages and the server pushes whatever changes.

    * "auth" – log in with username and password, get a token
    * "app" – projects, inbox, running sessions, routines, the composer
    * "session:<id>" – one session: messages, streamed text, send, stop, permissions
    * "project:<id>" – one project: sessions, runs, skills, schedules, settings
    * "admin" – users, connectors and secrets, model providers (admins only)

  Connect with `token` to be logged in. A missing or stale token still connects
  (so "auth" works); the other channels then refuse to join with "unauthorized".
  """
  use Phoenix.Socket

  channel "auth", BeamcodeWeb.AuthChannel
  channel "app", BeamcodeWeb.AppChannel
  channel "session:*", BeamcodeWeb.SessionChannel
  channel "project:*", BeamcodeWeb.ProjectChannel
  channel "admin", BeamcodeWeb.AdminChannel

  @impl true
  def connect(params, socket, _connect_info) do
    user =
      case BeamcodeWeb.AppToken.verify(params["token"]) do
        {:ok, user} -> user
        :error -> nil
      end

    {:ok, assign(socket, :user, user)}
  end

  @impl true
  def id(%{assigns: %{user: %{id: id}}}), do: "app_socket:#{id}"
  def id(_socket), do: nil
end
