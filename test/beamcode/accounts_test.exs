defmodule Beamcode.AccountsTest do
  use Beamcode.DataCase, async: true
  alias Beamcode.Accounts

  test "first user is admin, later users are not unless asked" do
    {:ok, first} = Accounts.create_user(%{"username" => "aksel", "password" => "password123"})
    {:ok, second} = Accounts.create_user(%{"username" => "marte", "password" => "password123"})

    {:ok, third} =
      Accounts.create_user(%{"username" => "ola", "password" => "password123"}, admin: true)

    assert first.admin
    refute second.admin
    assert third.admin
  end

  test "authenticates with the right password only" do
    {:ok, _} = Accounts.create_user(%{"username" => "aksel", "password" => "password123"})
    assert {:ok, %{username: "aksel"}} = Accounts.authenticate(" Aksel ", "password123")
    assert :error = Accounts.authenticate("aksel", "wrong-password")
    assert :error = Accounts.authenticate("nobody", "password123")
  end

  test "validates username and password" do
    assert {:error, cs} = Accounts.create_user(%{"username" => "Bad Name", "password" => "short"})
    assert %{username: [_], password: [_]} = errors_on(cs)
  end
end
