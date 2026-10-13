defmodule Beamcode.Projects.SessionRecord do
  @moduledoc "Who started an OpenCode session, from which project, and who may see it."
  use Ecto.Schema

  schema "session_records" do
    field :session_id, :string
    field :scope, :string, default: "team"
    field :schedule_key, :string
    # Operations Projects (see Beamcode.OpsChats): "procedure" or "run", the
    # procedure it's about, and the procedure file before the last message.
    field :chat, :string
    field :procedure, :string
    field :base, :string
    belongs_to :project, Beamcode.Projects.Project
    belongs_to :user, Beamcode.Accounts.User
    timestamps(type: :utc_datetime)
  end
end
