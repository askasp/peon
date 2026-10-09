defmodule Beamcode.Accounts do
  @moduledoc "Users: username and password, created by an admin. The first user is the admin."
  import Ecto.Query
  alias Beamcode.Repo
  alias Beamcode.Accounts.User

  def any_users?, do: Repo.exists?(User)

  def list_users, do: Repo.all(from u in User, order_by: u.username)

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_username(username), do: Repo.get_by(User, username: username)

  def authenticate(username, password) do
    user = get_user_by_username(String.downcase(String.trim(username || "")))
    if User.valid_password?(user, password), do: {:ok, user}, else: :error
  end

  @doc "Creates a user. The very first user always becomes admin."
  def create_user(attrs, opts \\ []) do
    admin? = Keyword.get(opts, :admin, false) or not any_users?()

    %User{admin: admin?}
    |> User.create_changeset(attrs)
    |> Repo.insert()
  end

  def change_user(user \\ %User{}, attrs \\ %{}), do: User.create_changeset(user, attrs)

  def change_password(user, attrs \\ %{}), do: User.password_changeset(user, attrs)

  def update_password(user, attrs), do: user |> User.password_changeset(attrs) |> Repo.update()

  def set_admin(user, admin?), do: user |> Ecto.Changeset.change(admin: admin?) |> Repo.update()

  def delete_user(user), do: Repo.delete(user)

  def update_keybinds(user, keybinds) when is_map(keybinds) do
    user |> Ecto.Changeset.change(keybinds: keybinds) |> Repo.update()
  end
end
