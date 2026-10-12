defmodule Beamcode.SchedulesPauseTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.Schedules

  setup do
    file =
      start_supervised!(
        {Agent, fn -> ~s({"nightly": {"cron": "0 2 * * *", "prompt": "Run"}}) end}
      )

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/fs/read/" <> _} ->
          Plug.Conn.send_resp(conn, 200, Agent.get(file, & &1))

        {"POST", "/api/experimental/fs/write"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(file, fn _ -> body end)
          data(conn, %{})
      end
    end)

    %{project: project_fixture(%{name: "app"}, nil)}
  end

  test "a paused schedule has no next run until it's resumed", %{project: project} do
    assert :ok = Schedules.set_paused(project, "nightly", true)
    {:ok, %{"nightly" => s}} = Schedules.read(project)
    assert s["paused"] == true
    assert %{paused: true, next: nil} = Schedules.decorate(project, "nightly", s)

    assert :ok = Schedules.set_paused(project, "nightly", false)
    {:ok, %{"nightly" => s}} = Schedules.read(project)
    refute Map.has_key?(s, "paused")
    assert %{paused: false, next: %NaiveDateTime{}} = Schedules.decorate(project, "nightly", s)

    assert {:error, _} = Schedules.set_paused(project, "missing", true)
  end
end
