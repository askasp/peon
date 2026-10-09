defmodule Beamcode.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :admin, :boolean, default: false
    field :keybinds, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def create_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> validate_format(:username, ~r/^[a-z0-9_.-]+$/, message: "lowercase letters, digits, . _ -")
    |> validate_length(:username, max: 40)
    |> unique_constraint(:username)
    |> password_changeset()
  end

  def password_changeset(changeset_or_user, attrs \\ %{}) do
    changeset_or_user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 128)
    |> then(fn cs ->
      case get_change(cs, :password) do
        nil -> cs
        pw -> put_change(cs, :password_hash, hash_password(pw))
      end
    end)
  end

  @iterations 210_000

  def hash_password(password) do
    salt = :crypto.strong_rand_bytes(16)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32)
    "pbkdf2-sha256$#{@iterations}$#{Base.encode64(salt)}$#{Base.encode64(hash)}"
  end

  def valid_password?(%__MODULE__{password_hash: "pbkdf2-sha256$" <> rest}, password)
      when is_binary(password) do
    with [iter, salt, hash] <- String.split(rest, "$"),
         {iter, ""} <- Integer.parse(iter),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, hash} <- Base.decode64(hash) do
      :crypto.hash_equals(hash, :crypto.pbkdf2_hmac(:sha256, password, salt, iter, 32))
    else
      _ -> false
    end
  end

  def valid_password?(_, _) do
    hash_password("timing-equalizer")
    false
  end
end
