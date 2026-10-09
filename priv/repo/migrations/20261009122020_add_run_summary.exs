defmodule Beamcode.Repo.Migrations.AddRunSummary do
  use Ecto.Migration

  def change do
    alter table(:schedule_runs) do
      add :summary, :text
      add :inputs, :map, null: false, default: %{}
    end
  end
end
