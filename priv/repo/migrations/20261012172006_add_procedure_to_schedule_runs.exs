defmodule Beamcode.Repo.Migrations.AddProcedureToScheduleRuns do
  use Ecto.Migration

  def change do
    alter table(:schedule_runs) do
      # Which procedure of the Folder ran (nil: from before Folders held many).
      add :procedure, :string
    end
  end
end
