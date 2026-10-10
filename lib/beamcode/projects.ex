defmodule Beamcode.Projects do
  @moduledoc """
  Projects are folders on the OpenCode server. This context tracks them,
  who can see them, and who started which session.

  Visibility rules:
    * `system` projects (setup) are for admins only
    * `private` projects are for their owner only
    * sessions recorded with scope `private` (e.g. "Only me" schedule runs)
      are only visible to the user who owns them
  """
  import Ecto.Query
  alias Beamcode.Repo
  alias Beamcode.Projects.{Project, SessionRecord}

  def topic, do: "projects"
  def subscribe, do: Phoenix.PubSub.subscribe(Beamcode.PubSub, topic())
  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Beamcode.PubSub, topic(), msg)

  def list_projects, do: Repo.all(from p in Project, order_by: [p.kind, p.name])

  def list_visible(user), do: list_projects() |> Enum.filter(&visible?(&1, user))

  def visible?(%Project{kind: "system"}, user), do: user.admin
  def visible?(%Project{scope: "private", owner_id: owner}, user), do: owner == user.id
  def visible?(%Project{}, _user), do: true

  def get_project(id), do: Repo.get(Project, id)
  def get_by_name(name), do: Repo.get_by(Project, name: name)

  def get_visible!(id, user) do
    project = Repo.get!(Project, id)
    if visible?(project, user), do: project, else: raise(Ecto.NoResultsError, queryable: Project)
  end

  def change_project(project \\ %Project{}, attrs \\ %{}), do: Project.changeset(project, attrs)

  def insert_project(attrs, owner) do
    %Project{owner_id: owner && owner.id}
    |> Project.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, p} -> broadcast({:project_changed, p})
      _ -> :ok
    end)
  end

  def put_oc_project_id(project, id) do
    project |> Ecto.Changeset.change(oc_project_id: id) |> Repo.update!()
  end

  def set_default_branch(project, branch) do
    project |> Project.default_branch_changeset(branch) |> Repo.update()
  end

  def update_settings(project, attrs) do
    project
    |> Project.settings_changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, p} -> broadcast({:project_changed, p})
      _ -> :ok
    end)
  end

  def set_github_repo(%Project{github_repo: repo} = project, repo), do: {:ok, project}

  def set_github_repo(project, repo) do
    project
    |> Project.github_changeset(%{github_repo: repo})
    |> Repo.update()
    |> tap(fn
      {:ok, p} -> broadcast({:project_changed, p})
      _ -> :ok
    end)
  end

  def delete_project(project) do
    Repo.delete(project) |> tap(fn _ -> broadcast({:project_changed, project}) end)
  end

  ## Sessions

  def record_session(session_id, project, user, opts \\ []) do
    %SessionRecord{
      session_id: session_id,
      project_id: project.id,
      user_id: user && user.id,
      scope: Keyword.get(opts, :scope, "team"),
      schedule_key: Keyword.get(opts, :schedule_key)
    }
    |> Repo.insert!(on_conflict: :nothing, conflict_target: :session_id)
  end

  def session_records(session_ids) do
    Repo.all(from r in SessionRecord, where: r.session_id in ^session_ids, preload: :user)
    |> Map.new(&{&1.session_id, &1})
  end

  def session_record(session_id),
    do: Repo.one(from r in SessionRecord, where: r.session_id == ^session_id, preload: :user)

  def session_visible?(nil, _user), do: true
  def session_visible?(%SessionRecord{scope: "private", user_id: uid}, user), do: uid == user.id
  def session_visible?(%SessionRecord{}, _user), do: true

  @doc """
  Finds our project for an OpenCode session map (or a location directory).
  Uses the session record first, then the OpenCode project id, then the folder.
  """
  def project_for_session(%{"id" => sid} = session, projects) do
    record = session_record(sid)

    (record && Enum.find(projects, &(&1.id == record.project_id))) ||
      Enum.find(projects, &(&1.oc_project_id && &1.oc_project_id == session["projectID"])) ||
      project_for_directory(get_in(session, ["location", "directory"]), projects)
  end

  def project_for_directory(nil, _projects), do: nil

  def project_for_directory(dir, projects) do
    projects
    |> Enum.filter(&(dir == &1.directory or String.starts_with?(dir, &1.directory <> "/")))
    |> Enum.max_by(&String.length(&1.directory), fn -> nil end)
  end
end
