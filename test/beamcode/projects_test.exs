defmodule Beamcode.ProjectsTest do
  use Beamcode.DataCase, async: true
  alias Beamcode.{Accounts, Projects}

  setup do
    {:ok, admin} = Accounts.create_user(%{"username" => "aksel", "password" => "password123"})
    {:ok, user} = Accounts.create_user(%{"username" => "marte", "password" => "password123"})
    %{admin: admin, user: user}
  end

  defp project(attrs, owner) do
    {:ok, p} =
      Projects.insert_project(
        Map.merge(%{directory: "/srv/#{attrs.name}", scope: "team"}, attrs),
        owner
      )

    p
  end

  test "team, private and system visibility", %{admin: admin, user: user} do
    team = project(%{name: "app", kind: "code"}, admin)
    private = project(%{name: "notes", kind: "chat", scope: "private"}, admin)
    system = project(%{name: "setup", kind: "system"}, nil)

    assert Projects.visible?(team, user)
    refute Projects.visible?(private, user)
    assert Projects.visible?(private, admin)
    refute Projects.visible?(system, user)
    assert Projects.visible?(system, admin)
    assert Enum.map(Projects.list_visible(user), & &1.name) == ["app"]
  end

  test "private sessions are only visible to their user", %{admin: admin, user: user} do
    p = project(%{name: "app", kind: "code"}, admin)
    Projects.record_session("ses_a", p, admin, scope: "private")
    Projects.record_session("ses_b", p, admin)
    records = Projects.session_records(["ses_a", "ses_b"])

    refute Projects.session_visible?(records["ses_a"], user)
    assert Projects.session_visible?(records["ses_a"], admin)
    assert Projects.session_visible?(records["ses_b"], user)
    assert Projects.session_visible?(nil, user)
  end

  test "maps sessions to projects by record, project id or folder", %{admin: admin} do
    a = project(%{name: "app", kind: "code"}, admin) |> Projects.put_oc_project_id("oc1")
    b = project(%{name: "b", kind: "routine", directory: "/srv/routines/b"}, admin)
    projects = [a, b]

    assert Projects.project_for_session(%{"id" => "x", "projectID" => "oc1"}, projects).id == a.id

    assert Projects.project_for_session(
             %{
               "id" => "y",
               "projectID" => "zz",
               "location" => %{"directory" => "/srv/routines/b/sub"}
             },
             projects
           ).id == b.id

    assert Projects.project_for_directory("/srv/other", projects) == nil
  end
end
