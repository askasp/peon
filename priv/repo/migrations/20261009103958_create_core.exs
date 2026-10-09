defmodule Beamcode.Repo.Migrations.CreateCore do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :admin, :boolean, null: false, default: false
      add :keybinds, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])

    create table(:projects) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :directory, :string, null: false
      add :scope, :string, null: false, default: "team"
      add :always_worktree, :boolean, null: false, default: false
      add :oc_project_id, :string
      add :owner_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:name])
    create unique_index(:projects, [:directory])

    create table(:session_records) do
      add :session_id, :string, null: false
      add :scope, :string, null: false, default: "team"
      add :schedule_key, :string
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:session_records, [:session_id])

    create table(:schedule_runs) do
      add :schedule_key, :string, null: false
      add :session_id, :string
      add :status, :string, null: false, default: "running"
      add :scope, :string, null: false, default: "team"
      add :error, :text
      add :seen, :boolean, null: false, default: false
      add :finished_at, :utc_datetime
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :owner_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:schedule_runs, [:project_id, :schedule_key])
    create index(:schedule_runs, [:session_id])

    create table(:secrets) do
      add :name, :string, null: false
      add :ciphertext, :binary, null: false
      add :set_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:secrets, [:name])
  end
end
