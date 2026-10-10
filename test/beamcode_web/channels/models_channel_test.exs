defmodule BeamcodeWeb.ModelsChannelTest do
  @moduledoc "Model providers on the admin channel: list, API keys, OAuth, disconnect."
  use BeamcodeWeb.ChannelCase, async: false

  import Beamcode.OpencodeStub
  alias BeamcodeWeb.UserSocket

  @integrations [
    %{
      "id" => "openai",
      "name" => "OpenAI",
      "methods" => [%{"type" => "key"}],
      "connections" => [
        %{
          "type" => "credential",
          "id" => "cred_1",
          "label" => "OAuth",
          "method" => "oauth",
          "status" => %{"message" => "token expired"}
        }
      ]
    },
    %{
      "id" => "opencode-go",
      "name" => "OpenCode Go",
      "methods" => [%{"type" => "key"}, %{"type" => "env", "names" => ["OPENCODE_API_KEY"]}],
      "connections" => []
    },
    %{
      "id" => "github-copilot",
      "name" => "GitHub Copilot",
      "methods" => [
        %{"id" => "device", "type" => "oauth", "label" => "Login with GitHub Copilot"}
      ],
      "connections" => []
    }
  ]

  setup do
    test = self()

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/integration"} ->
          data(conn, @integrations)

        {"GET", "/api/model"} ->
          data(conn, [%{"providerID" => "openai", "id" => "gpt-6", "name" => "GPT-6"}])

        {"GET", "/api/model/default"} ->
          data(conn, %{"providerID" => "openai", "id" => "gpt-6"})

        {"POST", "/api/integration/opencode-go/connect/key"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:connect_key, Jason.decode!(body)})
          no_content(conn)

        {"POST", "/api/integration/github-copilot/connect/oauth"} ->
          data(conn, %{
            "attemptID" => "att_1",
            "url" => "https://github.com/login/device",
            "instructions" => "Enter code ABCD-1234",
            "mode" => "auto",
            "time" => %{"created" => 0, "expires" => 1}
          })

        {"DELETE", "/api/integration/github-copilot/connect/oauth/att_1"} ->
          send(test, :cancelled)
          no_content(conn)

        {"GET", "/auth/callback"} ->
          send(test, {:callback, conn.host, conn.port, conn.query_string})
          Plug.Conn.send_resp(conn, 200, "Signed in")

        {"GET", "/api/integration/github-copilot/connect/oauth/att_1"} ->
          data(conn, %{"status" => "complete", "time" => %{"created" => 0, "expires" => 1}})

        {"DELETE", "/api/credential/cred_1"} ->
          send(test, :disconnected)
          no_content(conn)
      end
    end)

    {:ok, socket} = connect(UserSocket, token_params(user_fixture()))
    {:ok, _, socket} = subscribe_and_join(socket, "admin", %{})
    %{socket: socket}
  end

  defp start_copilot_sign_in(socket) do
    ref = push(socket, "start_oauth", %{"id" => "github-copilot", "method" => "device"})
    assert_reply ref, :ok, %{attempt: attempt}, 1000
    attempt
  end

  test "lists signed-in providers with their models", %{socket: socket} do
    ref = push(socket, "models", %{})
    assert_reply ref, :ok, reply, 1000
    assert reply.models == %{"openai" => ["GPT-6"]}

    assert reply.default == "openai/gpt-6"

    openai = Enum.find(reply.integrations, &(&1.id == "openai"))
    assert [%{id: "cred_1", problem: "token expired"}] = openai.connections
    assert Enum.any?(reply.integrations, &(&1.id == "opencode-go" and &1.connections == []))
  end

  test "connects OpenCode Go with an API key", %{socket: socket} do
    ref = push(socket, "connect_key", %{"id" => "opencode-go", "key" => " sk-go "})
    assert_reply ref, :ok, _, 1000
    assert_received {:connect_key, %{"key" => "sk-go", "answer" => nil}}
  end

  test "an OAuth sign-in returns its instructions and can be cancelled", %{socket: socket} do
    attempt = start_copilot_sign_in(socket)
    assert attempt["instructions"] =~ "ABCD-1234"
    assert attempt["url"] == "https://github.com/login/device"

    ref = push(socket, "cancel_oauth", %{})
    assert_reply ref, :ok, _
    assert_received :cancelled
  end

  test "a callback address pasted from another machine finishes the sign-in", %{socket: socket} do
    start_copilot_sign_in(socket)

    ref = push(socket, "paste_callback", %{"url" => "https://evil.example/auth/callback?code=x"})
    assert_reply ref, :error, %{message: _}, 1000
    refute_received {:callback, _, _, _}

    ref =
      push(socket, "paste_callback", %{
        "url" => " http://127.0.0.1:34429/auth/callback?code=ac_1&state=s1 "
      })

    assert_reply ref, :ok, _, 1000
    assert_received {:callback, "127.0.0.1", 34429, "code=ac_1&state=s1"}

    send(socket.channel_pid, :poll)
    assert_push "oauth", %{status: "complete"}
  end

  test "disconnects a credential", %{socket: socket} do
    ref = push(socket, "disconnect", %{"id" => "cred_1"})
    assert_reply ref, :ok, _, 1000
    assert_received :disconnected
  end
end
