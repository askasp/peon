defmodule BeamcodeWeb.ComposerChannelTest do
  @moduledoc "The global composer over the app channel: rules first, the model when unsure."
  use BeamcodeWeb.ChannelCase, async: false

  import Beamcode.OpencodeStub
  alias Beamcode.Projects
  alias BeamcodeWeb.UserSocket

  setup do
    test = self()
    user = user_fixture()

    {:ok, project} =
      Projects.insert_project(
        %{"name" => "amino-monorepo", "kind" => "code", "directory" => "/srv/amino"},
        user
      )

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/session"} ->
          data(conn, [
            %{"id" => "ses_old", "title" => "Old work", "time" => %{"updated" => 1}},
            %{"id" => "ses_new", "title" => "Fix checkout", "time" => %{"updated" => 2}}
          ])

        {"GET", "/api/session/ses_new/message"} ->
          data(conn, [
            %{
              "type" => "assistant",
              "content" => [%{"type" => "text", "text" => "The mock times out in `lib/mock.ex`."}]
            }
          ])

        {"POST", "/api/session"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          if String.ends_with?(Jason.decode!(body)["location"]["directory"], "/.composer"),
            do: data(conn, %{"id" => "ses_router"}),
            else: data(conn, %{"id" => "ses_1", "location" => %{"directory" => "/srv/amino"}})

        {"POST", "/api/session/ses_router/prompt"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:router_prompt, Jason.decode!(body)["text"]})
          data(conn, %{"id" => "msg_r"})

        {"GET", "/api/session/ses_router/message"} ->
          answer = %{
            "action" => "start_session",
            "project" => "amino-monorepo",
            "task" => "Fix the checkout test; it fails on CI.",
            "skill" => nil,
            "summary" => "Start a session in amino-monorepo to fix the checkout test."
          }

          data(conn, [
            %{
              "type" => "assistant",
              "time" => %{"completed" => 1},
              "content" => [%{"type" => "text", "text" => Jason.encode!(answer)}]
            }
          ])

        {"GET", "/api/fs/read/" <> _} ->
          Plug.Conn.send_resp(conn, 404, "")

        {"POST", "/api/experimental/fs/write"} ->
          data(conn, %{})

        {"DELETE", _} ->
          no_content(conn)

        {"POST", "/api/session/ses_1/prompt"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:prompt, Jason.decode!(body)})
          data(conn, %{"id" => "msg_1"})

        {"GET", "/api/session/ses_nope"} ->
          Plug.Conn.send_resp(conn, 404, ~s({"message":"not found"}))

        {"GET", "/api/skill"} ->
          data(conn, [%{"id" => "e2e-debug", "name" => "e2e-debug"}])

        _ ->
          data(conn, [])
      end
    end)

    {:ok, socket} = connect(UserSocket, token_params(user))
    {:ok, _reply, socket} = subscribe_and_join(socket, "app", %{})
    %{socket: socket, project: project}
  end

  test "previews the project, skill and task", %{socket: socket} do
    line = "new session in amino monorepo, use the e2e debug skill and then fix checkout"
    ref = push(socket, "compose:preview", %{"text" => line})
    assert_reply ref, :ok, %{preview: preview}
    assert preview.action == "session"
    assert ["Project", "amino-monorepo"] in preview.rows

    assert Enum.any?(preview.rows, fn [label, value] ->
             label =~ "Skill" and value =~ "e2e-debug"
           end)

    assert preview.button == "Start session"
  end

  test "starts the session, runs the skill and opens it", %{socket: socket} do
    line = "new session in amino monorepo, use the e2e debug skill and then fix checkout"
    ref = push(socket, "compose:submit", %{"text" => line})
    assert_reply ref, :ok, %{result: %{kind: "navigate", session_id: "ses_1"}}, 1000
    assert_received {:prompt, %{"text" => "fix checkout", "skills" => [%{"id" => "e2e-debug"}]}}
  end

  test "answers a status question in place, without starting a session", %{socket: socket} do
    text = "what is the status of the latest session in amino monorepo?"
    ref = push(socket, "compose:submit", %{"text" => text})
    assert_reply ref, :ok, %{result: %{kind: "answer"} = answer}, 1000
    assert answer.text =~ "Fix checkout"
    assert Enum.any?(answer.items, &(&1.id == "ses_new"))
    refute_received {:prompt, _}
  end

  test "a line the rules aren't sure of is read by the model, shown, then done on confirm",
       %{socket: socket} do
    line = "fiks checkout-testen i amino, den feiler på CI"

    ref = push(socket, "compose:preview", %{"text" => line})
    assert_reply ref, :ok, %{preview: preview}
    refute preview.sure

    ref = push(socket, "compose:submit", %{"text" => line})
    assert_reply ref, :ok, %{plan: plan}, 1000
    assert_received {:router_prompt, prompt}
    assert prompt =~ "amino-monorepo"
    assert prompt =~ line
    assert plan.summary =~ "Start a session in amino-monorepo"
    assert plan.button == "Start session"
    refute_received {:prompt, _}

    ref = push(socket, "compose:confirm", %{})
    assert_reply ref, :ok, %{result: %{kind: "navigate", session_id: "ses_1"}}, 1000
    assert_received {:prompt, %{"text" => "Fix the checkout test; it fails on CI."}}
  end

  test "the model is told which page you're on, but not a session you can't see",
       %{socket: socket, project: project} do
    ref =
      push(socket, "compose:submit", %{
        "text" => "fiks checkout-testen her",
        "current" => %{"project_id" => project.id, "session_id" => "ses_nope"}
      })

    assert_reply ref, :ok, _, 1000
    assert_received {:router_prompt, prompt}
    [_, context] = Regex.run(~r/Context:\n(.*)\n\nLine:/s, prompt)

    assert Jason.decode!(context)["current_page"] == %{
             "project" => "amino-monorepo",
             "session" => nil
           }
  end
end
