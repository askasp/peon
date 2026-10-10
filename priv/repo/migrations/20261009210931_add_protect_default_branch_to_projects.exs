defmodule Beamcode.Repo.Migrations.AddProtectDefaultBranchToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :protect_default_branch, :boolean, null: false, default: false
      add :default_branch, :string
    end
  end
end
