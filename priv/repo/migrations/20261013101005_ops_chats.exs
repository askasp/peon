defmodule Beamcode.Repo.Migrations.OpsChats do
  use Ecto.Migration

  # An Operations Project has no one chat: each procedure and each run has its
  # own. `chat` says which ("procedure" or "run"), `procedure` names it (nil
  # while a new procedure's chat hasn't written one yet), and `base` is the
  # procedure file before the chat's last message ("" when it didn't exist),
  # so the file view can show what changed and undo it.
  def change do
    alter table(:session_records) do
      add :chat, :string
      add :procedure, :string
      add :base, :text
    end

    create index(:session_records, [:project_id, :chat, :procedure])
  end
end
