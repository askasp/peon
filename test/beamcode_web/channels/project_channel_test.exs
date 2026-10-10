defmodule BeamcodeWeb.ProjectChannelTest do
  use BeamcodeWeb.ChannelCase, async: false

  import Beamcode.OpencodeStub
  alias BeamcodeWeb.UserSocket

  setup do
    admin = user_fixture(%{"username" => "aksel"})
    user = user_fixture(%{"username" => "marte"})
    app = project_fixture(%{name: "app"}, admin)
    notes = project_fixture(%{name: "notes", kind: "chat", scope: "private"}, admin)
    files = start_supervised!({Agent, fn -> %{} end})

    # A tiny OpenCode: files are kept in an Agent, skills come from the files.
    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"GET", "/api/fs/read/" <> path} ->
          case Agent.get(files, &Map.get(&1, URI.decode(path))) do
            nil -> Plug.Conn.send_resp(conn, 404, "")
            body -> Plug.Conn.send_resp(conn, 200, body)
          end

        {"POST", "/api/experimental/fs/write"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(files, &Map.put(&1, conn.query_params["path"], body))
          data(conn, %{})

        {"POST", "/api/location/reload"} ->
          data(conn, %{})

        {"GET", "/api/skill"} ->
          data(conn, [
            %{"name" => "review_pr", "path" => "/srv/app/.claude/skills/review_pr/SKILL.md"}
          ])

        # Agents, models: nothing to pick from.
        {"GET", _} ->
          data(conn, [])
      end
    end)

    %{admin: admin, user: user, app: app, notes: notes, files: files}
  end

  defp join_as(user, project) do
    {:ok, socket} = connect(UserSocket, token_params(user))
    subscribe_and_join(socket, "project:#{project.id}", %{})
  end

  test "only visible projects can be joined", %{user: user, app: app, notes: notes} do
    assert {:ok, %{project: %{name: "app"}, can_edit: false}, _} = join_as(user, app)
    assert {:error, %{reason: "not_found"}} = join_as(user, notes)
  end

  test "the editor opens AGENTS.md and skills, nothing else", %{admin: admin, app: app} do
    {:ok, _, socket} = join_as(admin, app)

    ref = push(socket, "save_file", %{"path" => "AGENTS.md", "content" => "# app"})
    assert_reply ref, :ok, %{}
    ref = push(socket, "read_file", %{"path" => "AGENTS.md"})
    assert_reply ref, :ok, %{content: "# app"}

    # A skill OpenCode found outside .opencode/skill/ opens too.
    ref = push(socket, "read_file", %{"path" => ".claude/skills/review_pr/SKILL.md"})
    assert_reply ref, :ok, %{path: ".claude/skills/review_pr/SKILL.md"}

    ref = push(socket, "read_file", %{"path" => "../../etc/passwd"})
    assert_reply ref, :error, %{message: "That file can't be opened here."}
    ref = push(socket, "save_file", %{"path" => "lib/app.ex", "content" => "x"})
    assert_reply ref, :error, %{message: "That file can't be saved here."}
  end

  test "creating a skill writes its SKILL.md from the template", %{
    admin: admin,
    app: app,
    files: files
  } do
    {:ok, _, socket} = join_as(admin, app)
    ref = push(socket, "create_skill", %{"name" => "Deploy"})
    assert_reply ref, :ok, %{path: ".opencode/skill/deploy/SKILL.md"}
    assert Agent.get(files, & &1[".opencode/skill/deploy/SKILL.md"]) =~ "name: deploy"

    ref = push(socket, "create_skill", %{"name" => "no spaces"})
    assert_reply ref, :error, %{message: "Skill names are lowercase letters, digits and dashes."}
  end

  test "schedules save from preset form values", %{admin: admin, app: app, files: files} do
    {:ok, _, socket} = join_as(admin, app)

    params = %{
      "key" => "nightly",
      "preset" => "weekdays",
      "at" => "06:30",
      "prompt" => "Run the tests"
    }

    ref = push(socket, "describe_schedule", %{"params" => params})
    assert_reply ref, :ok, %{cron: "30 6 * * 1-5"}

    ref = push(socket, "save_schedule", %{"params" => params})
    assert_reply ref, :ok, %{}

    saved = Jason.decode!(Agent.get(files, & &1["schedules.json"]))

    assert saved["nightly"] == %{
             "cron" => "30 6 * * 1-5",
             "prompt" => "Run the tests",
             "owner" => "aksel"
           }

    Beamcode.Repo.insert!(%Beamcode.Schedules.Run{
      project_id: app.id,
      owner_id: admin.id,
      session_id: "ses_run",
      schedule_key: "nightly",
      status: "failed",
      scope: "team",
      error: "tests timed out"
    })

    ref = push(socket, "schedules", %{})
    assert_reply ref, :ok, %{schedules: [nightly]}
    assert nightly.owner == "aksel"
    assert [%{status: "failed", error: "tests timed out", session_id: "ses_run"}] = nightly.runs

    ref = push(socket, "save_schedule", %{"params" => Map.put(params, "key", "Bad Name")})
    assert_reply ref, :error, %{message: "Name: lowercase letters, digits and dashes"}
  end

  test "a schedule runs as you unless an admin says otherwise; private ones stay private",
       %{admin: admin, user: user, app: app, files: files} do
    private = %{"cron" => "0 6 * * *", "prompt" => "Mine", "owner" => "aksel", "scope" => "me"}
    Agent.update(files, &Map.put(&1, "schedules.json", Jason.encode!(%{"secret" => private})))
    saved = fn -> Jason.decode!(Agent.get(files, & &1["schedules.json"])) end

    {:ok, _, socket} = join_as(user, app)
    params = %{"key" => "daily", "preset" => "daily", "at" => "07:00", "prompt" => "Hi"}

    # A member can't make it run as someone else.
    ref = push(socket, "save_schedule", %{"params" => Map.put(params, "owner", "aksel")})
    assert_reply ref, :ok, %{}
    assert saved.()["daily"]["owner"] == "marte"

    # Nor overwrite or delete someone's private schedule.
    ref = push(socket, "save_schedule", %{"params" => Map.put(params, "key", "secret")})
    assert_reply ref, :error, %{message: "No schedule by that name."}
    ref = push(socket, "delete_schedule", %{"key" => "secret"})
    assert_reply ref, :error, %{message: "No schedule by that name."}
    assert saved.()["secret"] == private

    # An admin can set the owner.
    {:ok, _, socket} = join_as(admin, app)
    ref = push(socket, "save_schedule", %{"params" => Map.put(params, "owner", "aksel")})
    assert_reply ref, :ok, %{}
    assert saved.()["daily"]["owner"] == "aksel"
  end

  test "a project made private closes for those who can't see it now",
       %{user: user, app: app} do
    {:ok, _, socket} = join_as(user, app)
    Process.unlink(socket.channel_pid)
    ref = Process.monitor(socket.channel_pid)

    {:ok, _} = Beamcode.Projects.update_settings(app, %{scope: "private"})

    assert_push "gone", %{}
    assert_receive {:DOWN, ^ref, :process, _, :normal}
  end

  test "settings are for the owner or an admin; removing is for admins", %{user: user, app: app} do
    {:ok, _, socket} = join_as(user, app)
    ref = push(socket, "save_settings", %{"params" => %{"always_worktree" => "true"}})
    assert_reply ref, :error, %{message: "Only the owner or an admin can change this."}
    ref = push(socket, "remove", %{})
    assert_reply ref, :error, %{message: "Admins only."}
  end

  test "an admin can change settings", %{admin: admin, app: app} do
    {:ok, _, socket} = join_as(admin, app)
    ref = push(socket, "save_settings", %{"params" => %{"always_worktree" => "true"}})
    assert_reply ref, :ok, %{project: %{always_worktree: true}, message: "Saved."}
  end

  test "runs list team runs and your own private ones only", %{admin: admin, user: user, app: app} do
    insert = fn owner, scope, summary ->
      Beamcode.Repo.insert!(%Beamcode.Schedules.Run{
        project_id: app.id,
        owner_id: owner.id,
        session_id: "ses_#{summary}",
        schedule_key: "manual",
        status: "done",
        scope: scope,
        summary: summary,
        inputs: %{"since" => "monday"}
      })
    end

    insert.(admin, "private", "admins-secret")
    insert.(admin, "team", "for-everyone")
    insert.(user, "private", "mine")

    {:ok, _, socket} = join_as(user, app)
    ref = push(socket, "runs", %{})
    assert_reply ref, :ok, %{runs: runs}
    assert runs |> Enum.map(& &1.summary) |> Enum.sort() == ["for-everyone", "mine"]
    assert Enum.find(runs, &(&1.summary == "for-everyone")).owner == "aksel"
    assert hd(runs).inputs == %{"since" => "monday"}
  end
end
