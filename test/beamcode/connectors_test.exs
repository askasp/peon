defmodule Beamcode.ConnectorsTest do
  use ExUnit.Case, async: true
  alias Beamcode.Connectors

  @front ~s({
    "name": "front",
    "baseUrl": "https://api2.frontapp.com",
    "auth": {"type": "bearer", "secret": "FRONT_TOKEN"},
    "tools": {
      "list_conversations": ["GET", "/inboxes/{inbox}/conversations", "allow"],
      "add_comment": ["post", "/conversations/{id}/comments", "ask", "Add a comment"],
      "archive": ["PATCH", "/conversations/{id}", "deny"]
    },
    "projects": ["front-digest"]
  })

  test "parses the design's connector format" do
    c = Connectors.parse("front.json", @front)
    assert c.error == nil
    assert c.secret == "FRONT_TOKEN"
    assert c.projects == ["front-digest"]
    assert Enum.map(c.tools, & &1.name) == ["add_comment", "archive", "list_conversations"]
    assert %{method: "POST", permission: "ask", description: "Add a comment"} = hd(c.tools)
  end

  test "reports invalid files" do
    assert Connectors.parse("x.json", "{nope").error

    assert Connectors.parse("x.json", ~s({"tools": {"a": ["GET", "/", "maybe"]}})).error =~
             "permission"

    assert Connectors.parse("x.json", ~s({"tools": {"a": ["FETCH", "/", "allow"]}})).error =~
             "method"
  end

  test "ready only with the secret, names follow the gateway" do
    c = Connectors.parse("front.json", @front)
    refute Connectors.ready?(c, MapSet.new())
    assert Connectors.ready?(c, MapSet.new(["FRONT_TOKEN"]))
    tool = hd(c.tools)
    assert Connectors.tool_name(c, tool) == "front_add_comment"
    assert Connectors.permission_action(c, tool) == "gateway_front_add_comment"
  end

  test "truncated bodies stay valid UTF-8" do
    body = String.duplicate("ø", 40_000)
    out = Connectors.truncate(body)
    assert String.valid?(out)
    assert out =~ "truncated"
    assert Jason.encode!(%{text: out})
  end

  test "compact drops _links and HTML bodies that have a text copy" do
    body =
      Jason.encode!(%{
        "_links" => %{"self" => "x"},
        "_results" => [
          %{"id" => "msg_1", "body" => "<p>hi</p>", "text" => "hi", "_links" => %{}},
          %{"id" => "com_1", "body" => "a comment"}
        ]
      })

    assert Jason.decode!(Connectors.compact(body)) == %{
             "_results" => [
               %{"id" => "msg_1", "text" => "hi"},
               %{"id" => "com_1", "body" => "a comment"}
             ]
           }

    assert Connectors.compact("not json") == "not json"
  end

  test "parses rateLimit and compact" do
    c =
      Connectors.parse(
        "x.json",
        ~s({"tools": {}, "rateLimit": {"perMinute": 40}, "compact": true})
      )

    assert c.per_minute == 40
    assert c.compact
  end

  test "429 waits as long as the API asks, capped" do
    front = %Req.Response{
      status: 429,
      body: ~s({"_error":{"message":"Rate limit exceeded. Please retry in 23463 milliseconds."}})
    }

    assert Connectors.retry_after_ms(front) == 23_713

    header = Req.Response.put_header(%Req.Response{status: 429, body: ""}, "retry-after", "5")
    assert Connectors.retry_after_ms(header) == 5_250

    long = Req.Response.put_header(%Req.Response{status: 429, body: ""}, "retry-after", "600")
    assert Connectors.retry_after_ms(long) == 30_000
  end
end
