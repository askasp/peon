defmodule BeamcodeWeb.SessionChannelTest do
  use BeamcodeWeb.ChannelCase, async: false

  import Beamcode.OpencodeStub
  alias Beamcode.Projects
  alias BeamcodeWeb.UserSocket

  @messages [
    %{
      "id" => "msg_2",
      "type" => "assistant",
      "time" => %{"completed" => 2},
      "content" => [%{"type" => "text", "text" => "The mock timed out. I raised the timeout."}]
    },
    %{
      "id" => "msg_1",
      "type" => "user",
      "text" => "Why does checkout fail?",
      "files" => [
        %{"mime" => "image/png", "data" => "aGVsbG8="},
        %{"mime" => "image/jpeg", "name" => "big.jpg", "data" => String.duplicate("A", 400_004)}
      ],
      "time" => %{"completed" => 1}
    }
  ]

  setup do
    admin = user_fixture(%{"username" => "aksel"})
    user = user_fixture(%{"username" => "marte"})
    app = project_fixture(%{name: "app"}, admin)
    Projects.record_session("ses_1", app, user)
    Projects.record_session("ses_private", app, admin, scope: "private")
    test = self()

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/session/" <> rest} ->
          case String.split(rest, "/") do
            [_id, "message"] ->
              data(conn, @messages)

            [_id, "diff"] ->
              data(conn, [
                %{
                  "file" => "lib/app.ex",
                  "additions" => 3,
                  "deletions" => 1,
                  "patch" => "@@ -1 +1 @@"
                }
              ])

            [id] ->
              data(conn, %{
                "id" => id,
                "title" => "Fix checkout",
                "location" => %{"directory" => "/srv/app"}
              })
          end

        {"POST", path} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:post, path, body})
          data(conn, %{})
      end
    end)

    {:ok, socket} = connect(UserSocket, token_params(user))
    %{socket: socket}
  end

  test "joining replies the session and its messages, oldest first", %{socket: socket} do
    {:ok, reply, _socket} = subscribe_and_join(socket, "session:ses_1", %{})
    assert reply.session.title == "Fix checkout"
    assert reply.project.name == "app"
    assert Enum.map(reply.messages, & &1["id"]) == ["msg_1", "msg_2"]
    # Small images come along; big ones are loaded on request (tested below).
    assert hd(hd(reply.messages)["files"]) == %{
             "mime" => "image/png",
             "name" => nil,
             "data" => "aGVsbG8="
           }

    assert [%{"file" => "lib/app.ex", "additions" => 3}] = reply.diff
  end

  test "someone else's private session can't be joined", %{socket: socket} do
    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(socket, "session:ses_private", %{})
  end

  test "send prompts the session", %{socket: socket} do
    {:ok, _, socket} = subscribe_and_join(socket, "session:ses_1", %{})
    ref = push(socket, "send", %{"text" => "open a PR"})
    assert_reply ref, :ok, %{}
    assert_received {:post, "/api/session/ses_1/prompt", body}
    assert Jason.decode!(body)["text"] == "open a PR"
  end

  test "streamed text is pushed as deltas", %{socket: socket} do
    {:ok, _, _socket} = subscribe_and_join(socket, "session:ses_1", %{})

    Phoenix.PubSub.broadcast(
      Beamcode.PubSub,
      "oc:session:ses_1",
      {:oc_event, "session.text.delta", %{"assistantMessageID" => "msg_3", "delta" => "Hel"}}
    )

    assert_push "delta", %{message_id: "msg_3", kind: "text", delta: "Hel"}
  end

  test "a finished turn refetches and says the reply", %{socket: socket} do
    {:ok, _, _socket} = subscribe_and_join(socket, "session:ses_1", %{})

    Phoenix.PubSub.broadcast(
      Beamcode.PubSub,
      "oc:session:ses_1",
      {:oc_event, "session.execution.succeeded", %{"sessionID" => "ses_1"}}
    )

    assert_push "speak", %{text: "The mock timed out. I raised the timeout."}
    # Nothing changed since join, so no messages push.
    refute_push "messages", _
  end

  test "a big pasted image is left out of the message and loaded on request", %{socket: socket} do
    {:ok, %{messages: messages}, socket} = subscribe_and_join(socket, "session:ses_1", %{})
    user = Enum.find(messages, &(&1["id"] == "msg_1"))
    assert [%{"data" => "aGVsbG8="}, %{"name" => "big.jpg", "data" => nil}] = user["files"]

    ref = push(socket, "image", %{"message_id" => "msg_1", "index" => 1})
    assert_reply ref, :ok, %{mime: "image/jpeg", data: data}, 1000
    assert byte_size(data) == 400_004

    ref = push(socket, "image", %{"message_id" => "msg_2", "index" => 0})
    assert_reply ref, :error, %{message: _}, 1000
  end

  test "send carries pasted images", %{socket: socket} do
    {:ok, _, socket} = subscribe_and_join(socket, "session:ses_1", %{})

    ref =
      push(socket, "send", %{
        "text" => "",
        "files" => [%{"uri" => "data:image/png;base64,aGVsbG8=", "name" => "shot.png"}]
      })

    assert_reply ref, :ok, %{}
    assert_received {:post, "/api/session/ses_1/prompt", body}

    assert [%{"uri" => "data:image/png;base64,aGVsbG8=", "name" => "shot.png"}] =
             Jason.decode!(body)["files"]
  end

  test "switching the agent updates the session for everyone watching", %{socket: socket} do
    {:ok, _, socket} = subscribe_and_join(socket, "session:ses_1", %{})
    ref = push(socket, "set_agent", %{"agent" => "plan"})
    assert_reply ref, :ok, %{}
    assert_received {:post, "/api/session/ses_1/agent", _}
    assert_push "session", %{session: %{agent: "plan"}}
  end

  test "run_again only works on routine runs", %{socket: socket} do
    {:ok, _, socket} = subscribe_and_join(socket, "session:ses_1", %{})
    ref = push(socket, "run_again", %{})
    assert_reply ref, :error, %{message: "This session isn't a routine run."}
  end

  test "a run finishing is pushed to its session", %{socket: socket} do
    project = Beamcode.Projects.list_projects() |> Enum.find(&(&1.name == "app"))

    run =
      Beamcode.Repo.insert!(%Beamcode.Schedules.Run{
        project_id: project.id,
        session_id: "ses_1",
        schedule_key: "manual",
        status: "running"
      })

    {:ok, %{run: %{status: "running"}}, _socket} =
      subscribe_and_join(socket, "session:ses_1", %{})

    run |> Ecto.Changeset.change(status: "done") |> Beamcode.Repo.update!()
    Phoenix.PubSub.broadcast(Beamcode.PubSub, "schedules", {:runs_changed, project.id})

    assert_push "run", %{run: %{status: "done"}}
  end
end
