defmodule Beamcode.Composer.PlanTest do
  use ExUnit.Case, async: true
  alias Beamcode.Composer.{Plan, Router}
  alias Beamcode.Projects.Project

  @amino %Project{id: 1, name: "amino-monorepo", kind: "code", directory: "/srv/amino"}
  @general %Project{id: 3, name: "general", kind: "chat", directory: "/srv/general"}
  @stripe %Project{id: 4, name: "stripe-reconcile", kind: "routine", directory: "/srv/stripe"}

  @ctx %{
    projects: [@amino, @general],
    routines: [@stripe],
    inputs: %{
      "stripe-reconcile" => [
        %{name: "since", default: "last run", options: ["last run", "this week"], multi: false}
      ]
    },
    connectors: ["front", "stripe"],
    sessions: [%{id: "ses_9", title: "Fix checkout", project: @amino, status: :idle, updated: 1}],
    perms: [
      %{
        perm: %{"id" => "per_1", "sessionID" => "ses_9"},
        title: "Fix checkout",
        asks: "Run mix test"
      }
    ],
    current: %{project: nil, session_id: nil}
  }

  test "start_session: names match loosely" do
    assert {:ok,
            %{
              action: :session,
              project: @amino,
              task: "fiks checkout",
              skill: nil,
              summary: "Start"
            }} =
             Plan.resolve(
               %{
                 "action" => "start_session",
                 "project" => "Amino Monorepo",
                 "task" => "fiks checkout",
                 "summary" => "Start"
               },
               @ctx
             )
  end

  test "start_session and chat: model and agent checked against the catalog" do
    ctx =
      Map.put(@ctx, :catalog, %{
        models: [
          %{value: "anthropic/claude-opus-4-1", name: "Claude Opus 4.1"},
          %{value: "openai/gpt-5", name: "GPT-5"}
        ],
        agents: ["build", "plan"],
        default_provider: nil
      })

    json = %{"action" => "start_session", "project" => "amino-monorepo", "task" => "fix it"}

    assert {:ok, %{use_model: %{value: "anthropic/claude-opus-4-1"}, agent: "plan"} = plan} =
             Plan.resolve(Map.merge(json, %{"model" => "Opus", "agent" => "Plan"}), ctx)

    assert {"Model", "Claude Opus 4.1"} in Plan.rows(plan)
    assert {"Agent", "plan"} in Plan.rows(plan)

    assert {:ok, %{use_model: nil, agent: nil}} = Plan.resolve(json, ctx)

    assert {:error, "No model called \"gpt-9\"."} =
             Plan.resolve(Map.put(json, "model", "gpt-9"), ctx)

    assert {:error, "No agent called \"ops\"."} = Plan.resolve(Map.put(json, "agent", "ops"), ctx)

    assert {:ok, %{action: :chat, use_model: %{value: "openai/gpt-5"}}} =
             Plan.resolve(%{"action" => "chat", "text" => "hi", "model" => "gpt 5"}, ctx)
  end

  test "create_routine: kebab name, known connectors only" do
    json = %{
      "action" => "create_routine",
      "name" => "Front Tilleggsrekvisisjon!",
      "brief" => "Read Front mail from the last 5 days and list who needs a tilleggsrekvisisjon.",
      "connectors" => ["front", "gmail"]
    }

    assert {:ok,
            %{action: :create_routine, name: "front-tilleggsrekvisisjon", connectors: ["front"]}} =
             Plan.resolve(json, @ctx)
  end

  test "run_routine keeps only the routine's inputs" do
    assert {:ok, %{action: :run, project: @stripe, inputs: %{"since" => "this week"}}} =
             Plan.resolve(
               %{
                 "action" => "run_routine",
                 "routine" => "stripe-reconcile",
                 "inputs" => %{"since" => "this week", "x" => 1}
               },
               @ctx
             )
  end

  test "send_to_session and permission check ids" do
    assert {:ok, %{action: :send, session: %{id: "ses_9"}}} =
             Plan.resolve(
               %{"action" => "send_to_session", "session" => "ses_9", "text" => "also docs"},
               @ctx
             )

    assert {:error, _} =
             Plan.resolve(
               %{"action" => "send_to_session", "session" => "nope", "text" => "x"},
               @ctx
             )

    assert {:ok, %{action: :permission, decision: "once", perm: %{title: "Fix checkout"}}} =
             Plan.resolve(
               %{"action" => "permission", "id" => "per_1", "decision" => "once"},
               @ctx
             )
  end

  test "unknown names and actions are errors, unclear asks back" do
    assert {:error, "No project called \"nope\"."} =
             Plan.resolve(
               %{"action" => "start_session", "project" => "nope", "task" => "x"},
               @ctx
             )

    assert {:error, _} = Plan.resolve(%{"action" => "fly"}, @ctx)

    assert {:ok, %{action: :unclear, question: "Which project?"}} =
             Plan.resolve(%{"action" => "unclear", "question" => "Which project?"}, @ctx)
  end

  test "status about a name we don't have says so instead of answering about another" do
    assert {:ok,
            %{
              action: :unclear,
              question: "There’s no project or procedure called “stripe reconcile”."
            }} =
             Plan.resolve(
               %{"action" => "status", "project" => "stripe reconcile", "scope" => "overview"},
               %{@ctx | routines: []}
             )

    assert {:ok, %{action: :status, project: nil}} =
             Plan.resolve(%{"action" => "status", "project" => nil}, @ctx)
  end

  test "create_routine lists services that aren't connected" do
    json = %{
      "action" => "create_routine",
      "name" => "x",
      "brief" => "Read Front and Gmail",
      "connectors" => ["front", "gmail"],
      "missing" => ["Gmail", "Slack"]
    }

    assert {:ok, %{connectors: ["front"], missing: ["Gmail", "Slack"]} = plan} =
             Plan.resolve(json, @ctx)

    assert {"Not connected", "Gmail, Slack" <> _} = List.last(Plan.rows(plan))
  end

  test "only read-only plans skip the confirm step" do
    refute Plan.confirm?(%{action: :status})
    refute Plan.confirm?(%{action: :unclear})
    assert Plan.confirm?(%{action: :create_routine})
    assert Plan.confirm?(%{action: :run})
  end

  test "Router.decode tolerates fences and prose" do
    assert {:ok, %{"action" => "chat"}} =
             Router.decode(~s(Sure:\n```json\n{"action": "chat", "text": "hi"}\n```))

    assert {:error, _} = Router.decode("no json here")
  end
end
