defmodule Beamcode.SourceSyncTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.{DataSources, Outbox, ProjectFiles, SourceTools, Vault}

  @moduletag :tmp_dir

  # OpenCode whose shell and files are the test folder's, so SQLite runs for
  # real; GitHub is a stub that keeps a tiny project in an Agent.
  setup %{tmp_dir: dir} do
    runs = start_supervised!({Agent, fn -> %{} end}, id: :runs)

    github =
      start_supervised!(
        {Agent,
         fn ->
           %{
             items: [
               item("PVTI_1", 214, "Sync engine", "In progress"),
               item("PVTI_2", 209, "Outbox", "Todo")
             ],
             mutations: [],
             fail: false
           }
         end},
        id: :github
      )

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/fs/read/" <> path} ->
          case File.read(Path.join(dir, URI.decode(path))) do
            {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
            _ -> Plug.Conn.send_resp(conn, 404, "")
          end

        {"POST", "/api/experimental/fs/write"} ->
          conn = Plug.Conn.fetch_query_params(conn)
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
      end
    end)

    Application.put_env(:beamcode, :source_req_options,
      plug: {Req.Test, Beamcode.SourceConnector}
    )

    Application.put_env(:beamcode, :outbox_inline, true)

    on_exit(fn ->
      Application.delete_env(:beamcode, :source_req_options)
      Application.delete_env(:beamcode, :outbox_inline)
    end)

    Req.Test.stub(Beamcode.SourceConnector, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"query" => query, "variables" => vars} = Jason.decode!(body)

      cond do
        Agent.get(github, & &1.fail) and String.starts_with?(query, "mutation") ->
          Req.Test.json(conn, %{"errors" => [%{"message" => "item is archived"}]})

        String.starts_with?(query, "mutation") ->
          Agent.update(github, &%{&1 | mutations: &1.mutations ++ [{query, vars["input"]}]})
          Req.Test.json(conn, %{"data" => %{}})

        true ->
          Req.Test.json(conn, %{"data" => project(Agent.get(github, & &1.items))})
      end
    end)

    {:ok, _} = Vault.put("GITHUB_TOKEN", "ghp_test", nil)
    project = project_fixture(%{name: "roadmap", kind: "dataset", directory: dir}, nil)
    {:ok, "github"} = DataSources.add(project, "github.projects", "stadler/12")

    %{project: project, github: github, dir: dir}
  end

  defp item(id, number, title, status) do
    %{
      "id" => id,
      "type" => "ISSUE",
      "isArchived" => false,
      "content" => %{
        "id" => "I_#{number}",
        "number" => number,
        "title" => title,
        "state" => "OPEN",
        "url" => "https://github.com/stadler/peon/issues/#{number}",
        "repository" => %{"nameWithOwner" => "stadler/peon"},
        "assignees" => %{"nodes" => [%{"login" => "aksel"}]},
        "labels" => %{"nodes" => []}
      },
      "fieldValues" => %{
        "nodes" => [
          %{"name" => status, "field" => %{"name" => "Status"}},
          %{"title" => "Oct 13", "field" => %{"name" => "Iteration"}}
        ]
      }
    }
  end

  defp project(items) do
    %{
      "repositoryOwner" => %{
        "projectV2" => %{
          "id" => "PVT_12",
          "title" => "Peon roadmap",
          "url" => "https://github.com/orgs/stadler/projects/12",
          "fields" => %{
            "nodes" => [
              %{"id" => "F_title", "name" => "Title", "dataType" => "TITLE"},
              %{
                "id" => "F_status",
                "name" => "Status",
                "dataType" => "SINGLE_SELECT",
                "options" => [
                  %{"id" => "o1", "name" => "Todo"},
                  %{"id" => "o2", "name" => "In progress"},
                  %{"id" => "o3", "name" => "Done"}
                ]
              },
              %{
                "id" => "F_iter",
                "name" => "Iteration",
                "dataType" => "ITERATION",
                "configuration" => %{
                  "iterations" => [
                    %{
                      "id" => "i1",
                      "title" => "Oct 13",
                      "startDate" => "2026-10-13",
                      "duration" => 14
                    }
                  ],
                  "completedIterations" => []
                }
              }
            ]
          },
          "items" => %{
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
            "nodes" => items
          }
        }
      }
    }
  end

  defp rows(project) do
    {:ok, rows} =
      ProjectFiles.query(project, "data.sqlite", "select * from items order by number")

    rows
  end

  test "a sync copies the project into items and keeps local columns", %{project: project} do
    assert :ok = DataSources.refresh(project, "github")

    assert [
             %{"number" => 209, "status" => "Todo", "iteration" => "Oct 13", "_pending" => 0},
             %{"number" => 214, "status" => "In progress", "assignees" => "aksel"}
           ] = rows(project)

    # A local column survives the next sync.
    {:ok, _} =
      ProjectFiles.exec(project, "data.sqlite", [
        {"alter table items add column note text", []},
        {"update items set note = 'start with GitHub' where number = 214", []}
      ])

    assert :ok = DataSources.refresh(project, "github")
    assert %{"note" => "start with GitHub"} = Enum.find(rows(project), &(&1["number"] == 214))

    assert [
             %{
               name: "github",
               connector: "github.projects",
               title: "Peon roadmap",
               rows: 2,
               waiting: 0
             }
           ] =
             DataSources.list(project)

    {:ok, [%{"options" => options}]} =
      ProjectFiles.query(
        project,
        "data.sqlite",
        "select options from _fields where col = 'status'"
      )

    assert options =~ "In progress"
  end

  test "items removed on GitHub are removed here", %{project: project, github: github} do
    :ok = DataSources.refresh(project, "github")
    Agent.update(github, &%{&1 | items: tl(&1.items)})
    :ok = DataSources.refresh(project, "github")
    assert [%{"number" => 209}] = rows(project)
  end

  test "a direct action posts at once; undo posts it back", %{project: project, github: github} do
    :ok = DataSources.refresh(project, "github")

    assert {:ok, %{"status" => "posting", "label" => "Status → Done"} = e} =
             Outbox.act(
               project,
               nil,
               "setField",
               "PVTI_2",
               %{"field" => "status", "value" => "done"},
               "app/board.html"
             )

    assert [%{"status" => "Done", "_pending" => 0} | _] = rows(project)
    assert [%{"status" => "posted", "origin" => "app/board.html"}] = Outbox.list(project)

    [{mutation, input}] = Agent.get(github, & &1.mutations)
    assert mutation =~ "updateProjectV2ItemFieldValue"

    assert input == %{
             "projectId" => "PVT_12",
             "itemId" => "PVTI_2",
             "fieldId" => "F_status",
             "value" => %{"singleSelectOptionId" => "o3"}
           }

    assert {:ok, %{"label" => "Status → Todo"}} = Outbox.undo(project, "data.sqlite", e["id"])
    assert [%{"status" => "Todo"} | _] = rows(project)
    assert [%{"status" => "posted"}, %{"status" => "undone"}] = Outbox.list(project)
  end

  test "a confirm action waits for Post, and can be edited first", %{
    project: project,
    github: github
  } do
    :ok = DataSources.refresh(project, "github")

    assert {:ok, %{"status" => "waiting", "id" => id}} =
             Outbox.act(project, "github", "comment", "PVTI_1", %{"body" => "Blocked"}, "chat")

    assert Agent.get(github, & &1.mutations) == []
    assert [%{waiting: 1}] = DataSources.list(project)

    assert :ok = Outbox.approve(project, "data.sqlite", id, %{"body" => "Blocked until #211"})

    assert [{m, %{"subjectId" => "I_214", "body" => "Blocked until #211"}}] =
             Agent.get(github, & &1.mutations)

    assert m =~ "addComment"
    assert [%{"status" => "posted"}] = Outbox.list(project)
  end

  test "off actions are refused, and unknown values are explained", %{project: project} do
    :ok = DataSources.refresh(project, "github")

    assert {:error, "Close an issue is off" <> _} =
             Outbox.act(project, nil, "close", "PVTI_1", %{}, "chat")

    assert {:error, "Status can be Todo, In progress, Done"} =
             Outbox.act(
               project,
               nil,
               "setField",
               "PVTI_1",
               %{"field" => "status", "value" => "Blocked"},
               "chat"
             )

    :ok = DataSources.set_level(project, "github", "close", "direct")

    assert {:ok, %{"status" => "posting"}} =
             Outbox.act(project, nil, "close", "PVTI_1", %{}, "chat")

    assert [_, %{"state" => "CLOSED"}] = rows(project)
  end

  test "a failed post puts the row back and can be retried", %{project: project, github: github} do
    :ok = DataSources.refresh(project, "github")
    Agent.update(github, &%{&1 | fail: true})

    {:ok, %{"id" => id}} =
      Outbox.act(
        project,
        nil,
        "setField",
        "PVTI_2",
        %{"field" => "status", "value" => "Done"},
        "chat"
      )

    assert [%{"status" => "Todo", "_pending" => 0} | _] = rows(project)
    assert [%{"status" => "failed", "error" => "GitHub: item is archived"}] = Outbox.list(project)
    assert [%{failed: 1}] = DataSources.list(project)

    Agent.update(github, &%{&1 | fail: false})
    assert :ok = Outbox.retry(project, "data.sqlite", id)
    assert [%{"status" => "Done"} | _] = rows(project)
    assert [%{"status" => "posted"}] = Outbox.list(project)
  end

  test "sync keeps a posting change on top, or fails it if GitHub changed the field", %{
    project: project,
    github: github
  } do
    :ok = DataSources.refresh(project, "github")

    posting = fn remote_id, value, before ->
      ProjectFiles.exec(project, "data.sqlite", [
        {"insert into _outbox (source, tbl, action, remote_id, args, label, level, status, origin, patch, before) values ('github', 'items', 'setField', ?, '{}', 'x', 'direct', 'posting', 'chat', ?, ?)",
         [remote_id, Jason.encode!(%{"status" => value}), Jason.encode!(%{"status" => before})]}
      ])
    end

    {:ok, _} = posting.("PVTI_2", "Done", "Todo")
    {:ok, _} = posting.("PVTI_1", "Todo", "In progress")

    # Someone moved #214 to Done on GitHub meanwhile; #209 is unchanged there.
    Agent.update(github, fn g ->
      %{
        g
        | items: [
            item("PVTI_1", 214, "Sync engine", "Done"),
            item("PVTI_2", 209, "Outbox", "Todo")
          ]
      }
    end)

    :ok = DataSources.refresh(project, "github")
    assert [%{"status" => "Done", "_pending" => 1}, %{"status" => "Done"}] = rows(project)

    assert [
             %{
               "status" => "failed",
               "error" => "status changed on GitHub Projects to Done (you set Todo)"
             },
             %{"status" => "posting"}
           ] =
             Outbox.list(project)
  end

  test "without a token the source says how to connect", %{project: project} do
    Vault.delete("GITHUB_TOKEN")

    assert {:error, "GitHub Projects isn't connected" <> _} =
             DataSources.refresh(project, "github")

    assert [%{error: "GitHub Projects isn't connected" <> _}] = DataSources.list(project)
  end

  test "a token without the project scope gets an honest error", %{project: _project} do
    # The account check still works; only listing projects is refused.
    Req.Test.stub(Beamcode.SourceConnector, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"query" => query} = Jason.decode!(body)

      if String.contains?(query, "projectsV2") do
        Req.Test.json(conn, %{
          "errors" => [
            %{
              "message" =>
                "Your token has not been granted the required scopes to execute this query. " <>
                  "The 'projectsV2' field requires one of the following scopes: ['read:project']"
            }
          ]
        })
      else
        Req.Test.json(conn, %{"data" => %{"viewer" => %{"login" => "aksel"}}})
      end
    end)

    assert {:error, message} = DataSources.choices("github.projects")
    assert message =~ "read:project scope"
    assert message =~ "GitHub said:"
  end

  test "the agent acts through the gateway tools, with the same levels", %{project: project} do
    :ok = DataSources.refresh(project, "github")
    assert [%{name: "source_act"}, %{name: "source_sync"}] = SourceTools.mcp_tools(project)

    assert {:ok, "Waiting in the Outbox" <> _} =
             SourceTools.call(project, "source_act", %{
               "action" => "comment",
               "row" => "PVTI_1",
               "args" => %{"body" => "Blocked"}
             })

    assert {:error, "Close an issue is off" <> _} =
             SourceTools.call(project, "source_act", %{"action" => "close", "row" => "PVTI_1"})

    assert {:ok, "github: synced"} = SourceTools.call(project, "source_sync", %{})
  end

  test "a Front inbox syncs its conversations and archives through the Outbox", %{
    project: project
  } do
    calls = start_supervised!({Agent, fn -> [] end}, id: :front)
    :ok = DataSources.remove(project, "github")
    {:ok, _} = Vault.put("FRONT_TOKEN", "front_test", nil)
    {:ok, "front"} = DataSources.add(project, "front", "")

    Req.Test.stub(Beamcode.SourceConnector, fn conn ->
      Agent.update(calls, &(&1 ++ [{conn.method, conn.request_path}]))

      case {conn.method, conn.request_path} do
        {"GET", "/conversations"} ->
          Req.Test.json(conn, %{
            "_pagination" => %{"next" => nil},
            "_results" => [
              %{
                "id" => "cnv_1",
                "subject" => "Kortet mitt ble avvist igjen",
                "status" => "unassigned",
                "recipient" => %{"name" => "Maja Holm", "handle" => "maja@example.no"},
                "tags" => [%{"name" => "payments"}],
                "created_at" => 1_791_500_000.5,
                "last_message" => %{
                  "is_inbound" => true,
                  "created_at" => 1_791_500_100,
                  "blurb" => "Hei, betalingen ble avvist",
                  "recipients" => [
                    %{"role" => "from", "handle" => "maja@example.no", "name" => "Maja Holm"}
                  ]
                }
              }
            ]
          })

        {"GET", "/teammates"} ->
          Req.Test.json(conn, %{"_results" => [%{"id" => "tea_1", "email" => "aksel@example.no"}]})

        {"PATCH", "/conversations/cnv_1"} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert :ok = DataSources.refresh(project, "front")

    {:ok, [row]} = ProjectFiles.query(project, "data.sqlite", "select * from conversations")

    assert %{
             "_remote_id" => "cnv_1",
             "contact" => "Maja Holm",
             "last_message" => "Hei, betalingen ble avvist",
             "last_message_from" => "Maja Holm",
             "last_message_inbound" => 1,
             "tags" => "payments",
             "status" => "unassigned"
           } = row

    assert {:ok, %{"status" => "posting"}} =
             Outbox.act(project, nil, "archive", "cnv_1", %{}, "app/inbox.html")

    {:ok, [%{"status" => "archived"}]} =
      ProjectFiles.query(project, "data.sqlite", "select status from conversations")

    assert {"PATCH", "/conversations/cnv_1"} in Agent.get(calls, & &1)

    assert {:error, "nobody@example.no isn't a teammate" <> _} =
             Outbox.act(project, nil, "assign", "cnv_1", %{"to" => "nobody@example.no"}, "chat")

    assert {:ok, %{"status" => "waiting"}} =
             Outbox.act(project, nil, "reply", "cnv_1", %{"body" => "Hei Maja"}, "chat")
  end
end
