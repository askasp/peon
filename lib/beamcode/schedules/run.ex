defmodule Beamcode.Schedules.Run do
  @moduledoc """
  One run of a routine or schedule. Each run is an ordinary session.
  `schedule_key` is the schedule's name, or "manual" for the Run button.
  """
  use Ecto.Schema

  schema "schedule_runs" do
    field :schedule_key, :string
    field :session_id, :string
    field :status, :string, default: "running"
    field :scope, :string, default: "team"
    field :error, :string
    field :seen, :boolean, default: false
    field :finished_at, :utc_datetime
    field :summary, :string
    field :inputs, :map, default: %{}
    belongs_to :project, Beamcode.Projects.Project
    belongs_to :owner, Beamcode.Accounts.User
    timestamps(type: :utc_datetime)
  end
end
