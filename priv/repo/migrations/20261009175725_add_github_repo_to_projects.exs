defmodule Beamcode.Repo.Migrations.AddGithubRepoToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      # owner/name on github.com, for code projects that push with a token.
      add :github_repo, :string
    end
  end
end
