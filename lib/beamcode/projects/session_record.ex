defmodule Beamcode.Projects.SessionRecord do
  @moduledoc "Who started an OpenCode session, from which project, and who may see it."
  use Ecto.Schema

  schema "session_records" do
    field :session_id, :string
    field :scope, :string, default: "team"
    field :schedule_key, :string
    belongs_to :project, Beamcode.Projects.Project
    belongs_to :user, Beamcode.Accounts.User
    timestamps(type: :utc_datetime)
  end
end
