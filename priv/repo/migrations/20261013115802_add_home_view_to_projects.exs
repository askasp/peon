defmodule Beamcode.Repo.Migrations.AddHomeViewToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :home_view, :string, null: false, default: "chat"
    end
  end
end
