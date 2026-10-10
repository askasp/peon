defmodule BeamcodeWeb.AuthChannelTest do
  use BeamcodeWeb.ChannelCase, async: true

  alias BeamcodeWeb.{AppToken, UserSocket}

  setup do
    user = user_fixture(%{"username" => "aksel", "password" => "password123"})
    {:ok, socket} = connect(UserSocket, %{})
    {:ok, _, socket} = subscribe_and_join(socket, "auth", %{})
    %{socket: socket, user: user}
  end

  test "login hands out a token for the user", %{socket: socket, user: user} do
    ref = push(socket, "login", %{"username" => "Aksel ", "password" => "password123"})
    assert_reply ref, :ok, %{token: token, user: %{username: "aksel"}}
    assert {:ok, %{id: id}} = AppToken.verify(token)
    assert id == user.id
  end

  test "a wrong password is refused", %{socket: socket} do
    ref = push(socket, "login", %{"username" => "aksel", "password" => "nope"})
    assert_reply ref, :error, %{message: "Wrong username or password."}
  end

  test "the token logs the socket in", %{user: user} do
    {:ok, socket} = connect(UserSocket, token_params(user))
    assert socket.assigns.user.id == user.id
    assert UserSocket.id(socket) == "app_socket:#{user.id}"
  end

  test "without a valid token only auth can be joined" do
    {:ok, socket} = connect(UserSocket, %{"token" => "forged"})
    assert socket.assigns.user == nil
    assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "app", %{})
    assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "session:ses_1", %{})
  end
end
