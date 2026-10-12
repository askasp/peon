defmodule Beamcode.Schedules.Run do
  @moduledoc """
  One run of a procedure or schedule. `schedule_key` is the schedule's name,
  or "manual" for anything a person started. `procedure` is which procedure
  ran and `trigger` how it started (slash, button, schedule, queue, chain).

  A run of steps (see `Beamcode.Procedures.Runs`) works in `session_id` (the
  chat it shows in) and keeps its place: `step` is the current step's index,
  `steps` what each did (`name`, `status`, `session_id`, `model`, `loops`,
  `text`), `outputs` what steps returned, and `waiting` what it asks of a
  person. A procedure started by another one's step has `parent_id`.
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
    field :procedure, :string
    field :trigger, :string
    field :step, :integer, default: 0
    field :steps, {:array, :map}, default: []
    field :outputs, :map, default: %{}
    field :waiting, :map
    field :ticket, :string
    belongs_to :parent, __MODULE__
    belongs_to :project, Beamcode.Projects.Project
    belongs_to :owner, Beamcode.Accounts.User
    timestamps(type: :utc_datetime)
  end
end
