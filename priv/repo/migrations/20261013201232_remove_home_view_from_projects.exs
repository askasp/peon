defmodule Beamcode.Repo.Migrations.RemoveHomeViewFromProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      remove :home_view
    end
  end
end
