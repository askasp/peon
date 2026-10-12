defmodule Beamcode.InboxTest do
  use BeamcodeWeb.ChannelCase, async: false

  alias Beamcode.{Inbox, Projects}
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
    %{admin: admin}
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
end
