defmodule Beamcode.Repo.Migrations.ProcedureRuns do
  use Ecto.Migration

  # Every procedure run, however it started, is a schedule_runs row; a run of
  # steps keeps where it is on the row.
  def change do
    alter table(:schedule_runs) do
      add :trigger, :string
      add :step, :integer, default: 0, null: false
      add :steps, {:array, :map}, default: [], null: false
      add :outputs, :map, default: %{}, null: false
      add :waiting, :map
      add :ticket, :string
      add :parent_id, references(:schedule_runs, on_delete: :nilify_all)
    end

    create index(:schedule_runs, [:parent_id])

    # A procedure's schedule is in its file; pausing it is Peon's, by name.
    alter table(:projects) do
      add :paused_schedules, {:array, :string}, default: [], null: false
    end
  end
end
