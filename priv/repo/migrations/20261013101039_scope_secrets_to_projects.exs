defmodule Beamcode.Repo.Migrations.ScopeSecretsToProjects do
  use Ecto.Migration

  # Every secret belongs to one Project. A code project's GitHub token
  # (GITHUB_TOKEN_<PROJECT>) moves to that project as GIT_TOKEN. The other old
  # shared ones stay without a project until `Beamcode.Vault.adopt_legacy/0`
  # copies them into the Projects that use them.
  def up do
    alter table(:secrets) do
      add :project_id, references(:projects, on_delete: :delete_all)
    end

    drop unique_index(:secrets, [:name])

    execute """
    UPDATE secrets s SET project_id = p.id, name = 'GIT_TOKEN'
    FROM projects p
    WHERE s.project_id IS NULL
      AND s.name = 'GITHUB_TOKEN_' || upper(replace(p.name, '-', '_'))
    """

    create unique_index(:secrets, [:project_id, :name])
  end

  def down do
    execute "DELETE FROM secrets WHERE project_id IS NOT NULL"
    drop unique_index(:secrets, [:project_id, :name])

    alter table(:secrets) do
      remove :project_id
    end

    create unique_index(:secrets, [:name])
  end
end
