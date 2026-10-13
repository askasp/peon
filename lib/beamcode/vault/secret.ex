defmodule Beamcode.Vault.Secret do
  use Ecto.Schema
  import Ecto.Changeset

  schema "secrets" do
    field :name, :string
    field :ciphertext, :binary, redact: true
    # nil only for old shared secrets not yet adopted (see Vault.adopt_legacy/0).
    belongs_to :project, Beamcode.Projects.Project
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
