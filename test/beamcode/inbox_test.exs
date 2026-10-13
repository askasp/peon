defmodule Beamcode.InboxTest do
  use BeamcodeWeb.ChannelCase, async: false

  alias Beamcode.{Inbox, Projects, Repo}
  alias Beamcode.Schedules.Run
  alias Beamcode.Opencode.Events

  # Events isn't started in tests; its tables are made here, as it would.
  setup do
    for t <- [:oc_session_status, :oc_pending_permissions, :oc_pending_forms, :oc_session_info],
        :ets.whereis(t) == :undefined,
        do: :ets.new(t, [:named_table, :public])

    admin = user_fixture(%{"username" => "aksel"})
    app = project_fixture(%{name: "app"}, admin)
    Projects.record_session("ses_1", app, admin)
    :ets.insert(:oc_session_info, {"ses_1", %{"id" => "ses_1", "title" => "Fix checkout"}})
    # A session with a pending ask is still running; that is what keeps it fresh.
    :ets.insert(:oc_session_status, {"ses_1", true})
    %{admin: admin, app: app}
  end

  test "a question the agent asked makes the session waiting and shows in the Inbox",
       %{admin: admin} do
    :ets.insert(
      :oc_pending_forms,
      {"frm_1",
       %{
         "id" => "frm_1",
         "sessionID" => "ses_1",
         "title" => "Questions",
         "fields" => [%{"key" => "q0", "type" => "string", "description" => "Which database?"}]
       }}
    )

    assert Events.status("ses_1") == :waiting

    assert [%{type: :question, form: %{"id" => "frm_1"}} = item] =
             Inbox.items(admin, Projects.list_projects())

    json = BeamcodeWeb.AppJSON.inbox_item(item)
    assert json.type == "question"
    assert json.form.text == "Which database?"
    assert json.session.title == "Fix checkout"
  end

  test "an ask left over from a session that stopped is stale and dropped", %{
    admin: admin,
    app: app
  } do
    # ses_9 is not running: its reply event was missed, so its ask is stale.
    :ets.insert(:oc_session_info, {"ses_9", %{"id" => "ses_9", "title" => "Old work"}})
    Projects.record_session("ses_9", app, admin)

    :ets.insert(
      :oc_pending_permissions,
      {"per_9",
       %{
         "id" => "per_9",
         "sessionID" => "ses_9",
         "action" => "shell",
         "resources" => ["git status"]
       }}
    )

    assert Inbox.items(admin, Projects.list_projects()) == []
  end

  test "a finished run is not in the Inbox; a waiting one is", %{admin: admin, app: app} do
    done =
      Repo.insert!(%Run{
        project_id: app.id,
        owner_id: admin.id,
        schedule_key: "nightly",
        procedure: "digest",
        trigger: "schedule",
        status: "done"
      })

    waiting =
      Repo.insert!(%Run{
        project_id: app.id,
        owner_id: admin.id,
        schedule_key: "nightly",
        procedure: "refund",
        trigger: "schedule",
        status: "waiting",
        waiting: %{"step" => 0, "kind" => "before", "text" => "Send 3 refunds?"}
      })

    assert [%{type: :run, run: %{id: id}}] = Inbox.items(admin, Projects.list_projects())
    refute id == done.id
    assert id == waiting.id
  end
end
