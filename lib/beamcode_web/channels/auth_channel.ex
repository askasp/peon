defmodule BeamcodeWeb.AuthChannel do
  @moduledoc """
  Logging in over the socket. `login` with `username` and `password` replies
  `{token, user}`; the app then reconnects with the token.
  """
  use BeamcodeWeb, :channel
  alias Beamcode.Accounts
  alias BeamcodeWeb.{AppJSON, AppToken}

  # Slows down password guessing; the channel process is the only thing waiting.
  @wrong_password_delay Application.compile_env(:beamcode, :app_login_delay, 1_000)

  @impl true
  def join("auth", _params, socket), do: {:ok, %{user: AppJSON.user(socket.assigns.user)}, socket}

  @impl true
  def handle_in("login", %{"username" => username, "password" => password}, socket)
      when is_binary(username) and is_binary(password) do
    case Accounts.authenticate(username, password) do
      {:ok, user} ->
        {:reply, {:ok, %{token: AppToken.sign(user), user: AppJSON.user(user)}}, socket}

      :error ->
        Process.sleep(@wrong_password_delay)
        {:reply, {:error, %{message: "Wrong username or password."}}, socket}
    end
  end

  def handle_in("login", _params, socket),
    do: {:reply, {:error, %{message: "Username and password are required."}}, socket}
end
