defmodule BeamcodeWeb.AppToken do
  @moduledoc """
  The phone app's login: a signed user id, handed out by the "auth" channel and
  sent back as the `token` param when the app opens `/socket`.

  The token carries a stamp of the user's password hash, so changing the
  password ends every token handed out before. `disconnect/1` closes a user's
  open sockets (after a password or role change, or removing them); they
  reconnect with their token, which is checked again.
  """
  alias Beamcode.Accounts

  @salt "app socket"
  @max_age 60 * 60 * 24 * 60

  def sign(user), do: Phoenix.Token.sign(BeamcodeWeb.Endpoint, @salt, {user.id, stamp(user)})

  @doc "`{:ok, user}` for a valid, unexpired token whose user still exists, else `:error`."
  def verify(token) when is_binary(token) do
    with {:ok, {id, stamp}} <-
           Phoenix.Token.verify(BeamcodeWeb.Endpoint, @salt, token, max_age: @max_age),
         %{} = user <- Accounts.get_user(id),
         true <- Plug.Crypto.secure_compare(stamp, stamp(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def verify(_), do: :error

  @doc "Closes the user's open app sockets (see `BeamcodeWeb.UserSocket.id/1`)."
  def disconnect(user_id),
    do: BeamcodeWeb.Endpoint.broadcast("app_socket:#{user_id}", "disconnect", %{})

  defp stamp(user),
    do: :crypto.hash(:sha256, user.password_hash || "") |> binary_part(0, 12) |> Base.encode64()
end
