defmodule BeamcodeWeb.AdminChannelTest do
  use BeamcodeWeb.ChannelCase, async: true

  alias Beamcode.Accounts
  alias BeamcodeWeb.UserSocket

  setup do
    admin = user_fixture(%{"username" => "aksel"})
    user = user_fixture(%{"username" => "marte"})
    %{admin: admin, user: user}
  end

  defp join_as(user) do
    {:ok, socket} = connect(UserSocket, token_params(user))
    subscribe_and_join(socket, "admin", %{})
  end

  test "only admins can join", %{user: user} do
    assert {:error, %{reason: "unauthorized"}} = join_as(user)
  end

  test "admins add users and change roles, but not their own", %{admin: admin, user: user} do
    {:ok, _, socket} = join_as(admin)

    ref =
      push(socket, "create_user", %{
        "username" => "ingrid",
        "password" => "password123",
        "admin" => false
      })

    assert_reply ref, :ok, %{user: %{username: "ingrid", admin: false}}

    ref = push(socket, "create_user", %{"username" => "x", "password" => "short"})
    assert_reply ref, :error, %{message: _}

    ref = push(socket, "toggle_admin", %{"id" => user.id})
    assert_reply ref, :ok, %{user: %{admin: true}}

    ref = push(socket, "toggle_admin", %{"id" => admin.id})
    assert_reply ref, :error, %{message: "You can't change your own admin role."}

    ref = push(socket, "delete_user", %{"id" => user.id})
    assert_reply ref, :ok, %{}
    assert Accounts.get_user(user.id) == nil
  end

  test "changing your password gives a new token and ends the old ones", %{user: user} do
    old = token_params(user)
    {:ok, socket} = connect(UserSocket, old)
    {:ok, _, socket} = subscribe_and_join(socket, "app", %{})
    BeamcodeWeb.Endpoint.subscribe("app_socket:#{user.id}")

    ref = push(socket, "change_password", %{"password" => "a-new-password"})
    assert_reply ref, :ok, %{token: token}
    assert {:ok, _} = Accounts.authenticate("marte", "a-new-password")

    # Open sockets are told to close; the old token no longer logs in, the new one does.
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert {:ok, %{assigns: %{user: nil}}} = connect(UserSocket, old)
    assert {:ok, %{assigns: %{user: %{id: id}}}} = connect(UserSocket, %{"token" => token})
    assert id == user.id
  end

  test "removing a user or changing their role closes their sockets", %{admin: admin, user: user} do
    {:ok, _, socket} = join_as(admin)
    BeamcodeWeb.Endpoint.subscribe("app_socket:#{user.id}")

    ref = push(socket, "toggle_admin", %{"id" => user.id})
    assert_reply ref, :ok, _
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

    ref = push(socket, "delete_user", %{"id" => user.id})
    assert_reply ref, :ok, _
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert {:ok, %{assigns: %{user: nil}}} = connect(UserSocket, token_params(user))
  end
end
