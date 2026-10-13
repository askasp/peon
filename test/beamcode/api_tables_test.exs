defmodule Beamcode.ApiTablesTest do
  # A Dataset's tables filled from its own API calls (`.peon/api/*.json`),
  # with nothing in Peon's code about the service.
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.{ApiTables, Connectors, DataSources, Outbox, ProjectFiles, SourceTools, Vault}

  @moduletag :tmp_dir

  @front %{
    "baseUrl" => "https://front.test",
    "auth" => %{"type" => "bearer", "secret" => "FRONT_TOKEN"},
    "tools" => %{
      "list_conversations" => ["GET", "/conversations", "allow", "List conversations"],
      "archive" => %{
        "method" => "PATCH",
        "path" => "/conversations/{id}",
        "permission" => "allow",
        "description" => "Archive a conversation",
        "body" => %{"status" => "archived"},
        "patch" => %{"status" => "archived"}
      },
      "reply" => ["POST", "/conversations/{id}/messages", "ask", "Reply"],
      "delete" => ["DELETE", "/conversations/{id}", "deny"]
    },
    "tables" => %{
      "conversations" => %{
        "call" => "list_conversations",
        "args" => %{"query" => %{"limit" => 2}},
        "rows" => "_results",
        "columns" => %{
          "subject" => "subject",
          "status" => "status",
          "assignee" => "assignee.email",
          "tags" => "tags[].name",
          "created_at" => %{"path" => "created_at", "type" => "time"}
        },
        "next" => "_pagination.next"
      }
    }
  }

  @github %{
    "baseUrl" => "https://github.test",
    "auth" => %{"type" => "bearer", "secret" => "GITHUB_TOKEN"},
    "tools" => %{
      "items" => %{
        "method" => "POST",
        "path" => "/graphql",
        "kind" => "read",
        "body" => %{
          "query" => "query($p: ID!, $after: String) { node(id: $p) { id } }",
          "variables" => %{"p" => "{project}", "after" => "{after}"}
        }
      }
    },
    "tables" => %{
      "items" => %{
        "call" => "items",
        "args" => %{"project" => "PVT_1"},
        "rows" => "data.node.items.nodes",
        "columns" => %{
          "number" => %{"path" => "content.number", "type" => "integer"},
          "title" => "content.title",
          "status" => %{
            "path" => "fieldValues.nodes[field.name=Status].name",
            "options" => ["Todo", "In progress", "Done"]
          }
        },
        "cursor" => %{"from" => "data.node.items.pageInfo.endCursor", "to" => "after"}
      }
    }
  }

  setup %{tmp_dir: dir} do
    runs = start_supervised!({Agent, fn -> %{} end}, id: :runs)
    calls = start_supervised!({Agent, fn -> [] end}, id: :calls)

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"GET", "/api/fs/list"} ->
          full = Path.join(dir, conn.query_params["path"])

          entries =
            for f <- if(File.dir?(full), do: File.ls!(full), else: []),
                do: %{"path" => Path.join(conn.query_params["path"], f), "type" => "file"}

          data(conn, entries)

        {"GET", "/api/fs/read/" <> path} ->
          case File.read(Path.join(dir, URI.decode(path))) do
            {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
            _ -> Plug.Conn.send_resp(conn, 404, "")
          end

        {"POST", "/api/experimental/fs/write"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          path = Path.join(dir, conn.query_params["path"])
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, body)
          data(conn, %{})

        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          {out, code} =
            System.cmd("sh", ["-c", Jason.decode!(body)["command"]],
              cd: dir,
              stderr_to_stdout: true
            )

          id = "sh#{System.unique_integer([:positive])}"
          Agent.update(runs, &Map.put(&1, id, {code, out}))
          data(conn, %{"id" => id})

        {"GET", "/api/shell/" <> rest} ->
          case String.split(rest, "/") do
            [id] ->
              data(conn, %{"status" => "done", "exit" => elem(Agent.get(runs, & &1[id]), 0)})

            [id, "output"] ->
              data(conn, %{"output" => elem(Agent.get(runs, & &1[id]), 1)})
          end

        _ ->
          data(conn, %{})
      end
    end)

    Application.put_env(:beamcode, :connector_req_options, plug: {Req.Test, :api_tables})
    Application.put_env(:beamcode, :outbox_inline, true)

    on_exit(fn ->
      Application.put_env(:beamcode, :connector_req_options, [])
      Application.delete_env(:beamcode, :outbox_inline)
    end)

    Req.Test.stub(:api_tables, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(calls, &(&1 ++ [{conn.method, conn.request_path, conn.query_params, body}]))

      case {conn.method, conn.host, conn.request_path, conn.query_params} do
        {"GET", "front.test", "/conversations", %{"page" => "2"}} ->
          Req.Test.json(conn, %{
            "_pagination" => %{"next" => nil},
            "_results" => [conversation("cnv_3", "Third", [])]
          })

        {"GET", "front.test", "/conversations", _} ->
          Req.Test.json(conn, %{
            "_pagination" => %{"next" => "https://front.test/conversations?page=2"},
            "_results" => [
              conversation("cnv_1", "Kortet ble avvist", ["payments", "urgent"]),
              conversation("cnv_2", "Mentions #214", [])
            ]
          })

        {"PATCH", "front.test", "/conversations/" <> _, _} ->
          Req.Test.json(conn, %{})

        {"POST", "github.test", "/graphql", _} ->
          after_ = Jason.decode!(body)["variables"]["after"]

          {nodes, cursor} =
            if after_ == nil,
              do: {[item("PVTI_1", 214, "Sync engine", "In progress")], "c1"},
              else: {[item("PVTI_2", 209, "Outbox", "Todo")], nil}

          Req.Test.json(conn, %{
            "data" => %{
              "node" => %{
                "items" => %{"pageInfo" => %{"endCursor" => cursor}, "nodes" => nodes}
              }
            }
          })
      end
    end)

    project = project_fixture(%{name: "roadmap", kind: "dataset", directory: dir}, nil)
    write_api(dir, "front", @front)
    %{project: project, dir: dir, calls: calls}
  end

  defp write_api(dir, name, json) do
    File.mkdir_p!(Path.join(dir, ".peon/api"))
    File.write!(Path.join(dir, ".peon/api/#{name}.json"), Jason.encode!(json))
  end

  defp conversation(id, subject, tags) do
    %{
      "id" => id,
      "subject" => subject,
      "status" => "open",
      "assignee" => %{"email" => "aksel@stadler.no"},
      "tags" => Enum.map(tags, &%{"name" => &1}),
      "created_at" => 1_791_500_000
    }
  end

  defp item(id, number, title, status) do
    %{
      "id" => id,
      "content" => %{"number" => number, "title" => title},
      "fieldValues" => %{
        "nodes" => [
          %{"title" => "Oct 13", "field" => %{"name" => "Iteration"}},
          %{"name" => status, "field" => %{"name" => "Status"}}
        ]
      }
    }
  end

  defp rows(project, table),
    do: ProjectFiles.query(project, "data.sqlite", "select * from #{table} order by _remote_id")

  test "a table waits for its token, then syncs every page", %{project: project} do
    assert %{"conversations" => s} = DataSources.connector_sources(project)
    refute DataSources.ready?(project, s)

    assert {:error, "secret FRONT_TOKEN is not set" <> _} =
             DataSources.refresh(project, "conversations")

    {:ok, _} = Vault.put(project, "FRONT_TOKEN", "front_test", nil)
    assert DataSources.ready?(project, s)
    assert :ok = DataSources.refresh(project, "conversations")

    assert {:ok, [one, two, three]} = rows(project, "conversations")
    assert one["subject"] == "Kortet ble avvist"
    assert one["tags"] == "payments, urgent"
    assert one["assignee"] == "aksel@stadler.no"
    assert one["created_at"] =~ ~r/^2026-/
    assert two["tags"] == nil
    assert three["_remote_id"] == "cnv_3"

    assert [%{name: "conversations", api: "front", rows: 3, error: nil}] =
             DataSources.list(project)
  end

  test "the user's own columns survive a sync", %{project: project} do
    {:ok, _} = Vault.put(project, "FRONT_TOKEN", "front_test", nil)
    :ok = DataSources.refresh(project, "conversations")

    {:ok, _} =
      ProjectFiles.exec(project, "data.sqlite", [
        {"alter table conversations add column issue integer", []},
        {"update conversations set issue = 214 where _remote_id = 'cnv_2'", []}
      ])

    :ok = DataSources.refresh(project, "conversations")
    assert {:ok, [_, %{"issue" => 214}, _]} = rows(project, "conversations")
  end

  test "a GraphQL read pages with its cursor and picks fields by name", %{
    project: project,
    dir: dir,
    calls: calls
  } do
    write_api(dir, "github", @github)
    Connectors.changed(project)
    {:ok, _} = Vault.put(project, "GITHUB_TOKEN", "ghp", nil)

    assert :ok = DataSources.refresh(project, "items")

    assert {:ok, [%{"number" => 214, "status" => "In progress"}, %{"title" => "Outbox"}]} =
             rows(project, "items")

    assert {:ok, [%{"options" => options}]} =
             ProjectFiles.query(
               project,
               "data.sqlite",
               "select options from _fields where col = 'status'"
             )

    assert Jason.decode!(options) == ["Todo", "In progress", "Done"]

    bodies = for {"POST", "/graphql", _, body} <- Agent.get(calls, & &1), do: Jason.decode!(body)

    assert [
             %{"variables" => %{"p" => "PVT_1", "after" => nil}},
             %{"variables" => %{"after" => "c1"}}
           ] = bodies
  end

  test "write calls are actions whose level is the call's permission", %{
    project: project,
    calls: calls
  } do
    {:ok, _} = Vault.put(project, "FRONT_TOKEN", "front_test", nil)
    :ok = DataSources.refresh(project, "conversations")

    # allow: posts at once, with the row's id in the path and the call's body.
    assert {:ok, %{"status" => "posting"}} =
             Outbox.act(project, "conversations", "archive", "cnv_1", %{}, "view")

    assert {"PATCH", "/conversations/cnv_1", _, body} = List.last(Agent.get(calls, & &1))
    assert Jason.decode!(body) == %{"status" => "archived"}
    assert [%{"status" => "posted"}] = Outbox.list(project)

    # ask: waits in the Outbox; deny: refused.
    assert {:ok, %{"status" => "waiting"}} =
             Outbox.act(
               project,
               "conversations",
               "reply",
               "cnv_2",
               %{"body" => %{"text" => "Hi"}},
               "chat"
             )

    assert {:error, _} = Outbox.act(project, "conversations", "delete", "cnv_2", %{}, "chat")

    # Setting a level writes the permission back to the file.
    assert :ok = DataSources.set_level(project, "conversations", "reply", "direct")
    Connectors.changed(project)
    assert %{tools: tools} = Connectors.find(project, "front")
    assert Enum.find(tools, &(&1.name == "reply")).permission == "allow"
  end

  test "the agent sees the actions and syncs through the gateway", %{project: project} do
    {:ok, _} = Vault.put(project, "FRONT_TOKEN", "front_test", nil)

    assert [%{name: "source_act", description: d}, %{name: "source_sync"}] =
             SourceTools.mcp_tools(project)

    assert d =~ "archive (direct)"
    assert d =~ "reply (confirm)"
    assert {:ok, "conversations: synced"} = SourceTools.call(project, "source_sync", %{})
  end

  test "ask_token never takes the token itself", %{project: project} do
    assert {:ok, text} =
             Connectors.ask_token(project, %{"name" => "FRONT_TOKEN", "service" => "front"})

    assert text =~ "card"
    assert {:error, _} = Connectors.ask_token(project, %{"name" => "front token"})

    {:ok, _} = Vault.put(project, "FRONT_TOKEN", "front_test", nil)

    assert {:ok, "FRONT_TOKEN is already set" <> _} =
             Connectors.ask_token(project, %{"name" => "FRONT_TOKEN"})
  end

  test "paths pick keys, every item, one item and the first match" do
    data = %{"a" => [%{"k" => "x", "v" => 1}, %{"k" => "y", "v" => 2}]}
    assert ApiTables.dig(data, "a[].v") == [1, 2]
    assert ApiTables.dig(data, "a[1].k") == "y"
    assert ApiTables.dig(data, "a[k=y].v") == 2
    assert ApiTables.dig(data, "a[k=z].v") == nil
    assert ApiTables.dig([1, 2], "") == [1, 2]
  end

  test "a table must name one of the file's calls" do
    bad =
      Jason.encode!(
        Map.put(@front, "tables", %{"t" => %{"call" => "nope", "columns" => %{"a" => "a"}}})
      )

    assert %{error: "table t: \"call\" must name one of this file's tools"} =
             Connectors.parse("x.json", bad)
  end
end
