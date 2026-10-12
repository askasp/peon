defmodule Beamcode.Repo.Migrations.AddQueueAutoToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      # Code Folders: start a worktree's next ready task when one finishes.
      add :queue_auto, :boolean, default: true, null: false
    end
  end
end
