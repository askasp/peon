defmodule BeamcodeWeb.ModelsLiveTest do
  use BeamcodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Beamcode.OpencodeStub

  @integrations [
    %{
      "id" => "openai",
      "name" => "OpenAI",
      "methods" => [%{"type" => "key"}],
      "connections" => [
        %{"type" => "credential", "id" => "cred_1", "label" => "OAuth", "method" => "oauth"}
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
  end

  test "lists signed-in providers with their models", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/models")

    assert render_async(view) =~ "GPT-6"
    assert has_element?(view, "#provider-openai")
    assert has_element?(view, "#default-model", "openai/gpt-6")
    refute has_element?(view, "#pick-openai")
    assert has_element?(view, "#pick-opencode-go")
  end

  test "connects OpenCode Go with an API key", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/models")
    render_async(view)

    view |> element("#pick-opencode-go") |> render_click()
    assert has_element?(view, "#connect-key-form")

    view |> form("#connect-key-form", connect: %{key: "sk-go"}) |> render_submit()
    render_async(view)

    assert_received {:connect_key, %{"key" => "sk-go", "answer" => nil}}
  end

  test "an OAuth sign-in shows its instructions and can be cancelled", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/models")
    render_async(view)

    view |> element("#pick-github-copilot") |> render_click()
    view |> form("#connect-oauth-device") |> render_submit()
    render_async(view)

    assert has_element?(view, "#oauth-attempt", "ABCD-1234")
    assert has_element?(view, "#oauth-open[href='https://github.com/login/device']")

    view |> element("#oauth-cancel") |> render_click()
    assert_received :cancelled
    refute has_element?(view, "#oauth-attempt")
  end

  test "a callback address pasted from another machine finishes the sign-in", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/models")
    render_async(view)

    view |> element("#pick-github-copilot") |> render_click()
    view |> form("#connect-oauth-device") |> render_submit()
    render_async(view)

    view
    |> form("#oauth-callback-form", url: "https://evil.example/auth/callback?code=x")
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#connect-error")
    refute_received {:callback, _, _, _}

    view
    |> form("#oauth-callback-form",
      url: " http://127.0.0.1:34429/auth/callback?code=ac_1&state=s1 "
    )
    |> render_submit()

    render_async(view)
    assert_received {:callback, "127.0.0.1", 34429, "code=ac_1&state=s1"}

    render_async(view)
    refute has_element?(view, "#oauth-attempt")
    assert render(view) =~ "is connected"
  end

  test "disconnects a credential", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/models")
    render_async(view)

    view |> element("#disconnect-cred_1") |> render_click()
    assert_received :disconnected
  end

  test "only admins see it", %{conn: conn} do
    _admin = user_fixture()

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in_user(user_fixture()) |> live(~p"/models")
  end
end
