defmodule Beamcode.Vault.Secret do
  use Ecto.Schema
  import Ecto.Changeset

  schema "secrets" do
    field :name, :string
    field :ciphertext, :binary, redact: true
    belongs_to :set_by, Beamcode.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[A-Z][A-Z0-9_]*$/, message: "UPPER_SNAKE_CASE")
  end
end
