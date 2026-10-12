defmodule Beamcode.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  # A project is a Folder in the app; its kind is the template it was made
  # from. chat, document, design, dataset and home all behave like chat.
  @kinds ~w(code routine chat document design dataset home system)
  @chat_like ~w(chat document design dataset home)
  # One working copy of their files, so one continuous chat (code chats each
  # get a worktree; chat and home hold unrelated talks with no files to share).
  # An Operations Folder's (routine) chat is where its procedures run.
  @single_chat ~w(document design dataset routine)
  @scopes ~w(team private)

  schema "projects" do
    field :name, :string
    field :kind, :string
    field :directory, :string
    field :scope, :string, default: "team"
    field :always_worktree, :boolean, default: false
    field :oc_project_id, :string
    field :github_repo, :string
    # No pushes to main/master/default_branch (see Beamcode.BranchGuard).
    field :protect_default_branch, :boolean, default: false
    field :default_branch, :string
    # Code Folders: a worktree starts its next ready task when one finishes.
    field :queue_auto, :boolean, default: true
    # Procedures whose file schedule is paused (see Beamcode.Procedures.Schedule).
    field :paused_schedules, {:array, :string}, default: []
    belongs_to :owner, Beamcode.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc "Kinds that are a plain folder for chatting and making files (no git, no routine)."
  def chat_like?(%__MODULE__{kind: kind}), do: kind in @chat_like
  def chat_like?(kind) when is_binary(kind), do: kind in @chat_like

  @doc "Kinds whose Folder is one chat beside its files (see `Beamcode.Sessions.folder_chat/2`)."
  def single_chat?(%__MODULE__{kind: kind}), do: kind in @single_chat
  def single_chat?(kind) when is_binary(kind), do: kind in @single_chat

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :kind, :directory, :scope, :always_worktree, :github_repo])
    |> validate_required([:name, :kind, :directory, :scope])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "lowercase letters, digits and dashes"
    )
    |> validate_length(:name, max: 48)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:scope, @scopes)
    |> unique_constraint(:name)
    |> unique_constraint(:directory)
    |> validate_github_repo()
  end

  def settings_changeset(project, attrs) do
    project
    |> cast(attrs, [:scope, :always_worktree, :protect_default_branch, :queue_auto])
    |> validate_inclusion(:scope, @scopes)
  end

  def default_branch_changeset(project, branch) do
    project
    |> change(default_branch: branch)
    |> validate_format(:default_branch, ~r{^[A-Za-z0-9._/-]+$})
  end

  def github_changeset(project, attrs) do
    project
    |> cast(attrs, [:github_repo])
    |> validate_github_repo()
  end

  defp validate_github_repo(changeset) do
    validate_format(changeset, :github_repo, ~r{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$},
      message: "owner/name"
    )
  end
end
