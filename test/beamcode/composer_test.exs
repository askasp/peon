defmodule Beamcode.ComposerTest do
  use ExUnit.Case, async: true
  alias Beamcode.Composer
  alias Beamcode.Projects.Project

  @projects [
    %Project{id: 1, name: "amino-monorepo", kind: "code"},
    %Project{id: 2, name: "chatos-web", kind: "code"},
    %Project{id: 3, name: "general", kind: "chat"},
    %Project{id: 4, name: "stripe-reconcile", kind: "routine"},
    %Project{id: 5, name: "setup", kind: "system"}
  ]

  defp read(text) do
    p = Composer.parse(text, @projects)
    {p.action, p.project && p.project.name, p.skill, p.task}
  end

  test "an empty line reads as nothing" do
    assert Composer.parse("   ", @projects) == nil
  end

  test "spoken: project with spaces, skill by name, filler dropped" do
    assert read(
             "create new session in amino monorepo, use the e2e debug skill and then find out why the checkout test fails on CI"
           ) ==
             {:session, "amino-monorepo", "e2e-debug",
              "find out why the checkout test fails on CI"}
  end

  test "typed: exact name and /skill" do
    assert read("new session in amino-monorepo, use /e2e-debug and then find why checkout fails") ==
             {:session, "amino-monorepo", "e2e-debug", "find why checkout fails"}
  end

  test "@project, any case" do
    assert read("@chatos-web fix the login button") ==
             {:session, "chatos-web", nil, "fix the login button"}

    assert read("In Amino Monorepo, bump the elixir version") ==
             {:session, "amino-monorepo", nil, "bump the elixir version"}
  end

  test "run a routine, also by the first part of its name" do
    assert read("run stripe-reconcile") == {:run, "stripe-reconcile", nil, ""}
    assert read("kick off stripe") == {:run, "stripe-reconcile", nil, ""}
  end

  test "a question about a project keeps the whole question" do
    assert read("what changed in chatos-web this week?") ==
             {:ask, "chatos-web", nil, "what changed in chatos-web this week?"}
  end

  test "no project named: the chat project" do
    assert {:chat, "general", nil, "how do I write a haiku?"} = read("how do I write a haiku?")
  end

  describe "sure: plain lines run on Enter, the rest go to the model" do
    defp sure?(text), do: Composer.parse(text, @projects).sure

    test "sure" do
      assert sure?("run stripe-reconcile")
      assert sure?("run routine stripe reconcile now")
      assert sure?("new session in amino monorepo, fix checkout")
      assert sure?("@chatos-web fix the login button")
      assert sure?("anything waiting?")
      assert sure?("what is the status of the latest session in amino-monorepo")
    end

    test "not sure" do
      refute sure?("Createa new routine which speaks to front and reads emailsfor last 5days")
      refute sure?("run the stripe one for this week, only Support")
      refute sure?("how is stripe reconcile doing")
      refute sure?("fiks checkout-testen i amino")
      refute sure?("what changed in chatos-web this week?")
    end
  end

  test "names only match whole words; system projects are not targets" do
    assert {:chat, "general", nil, _} = read("tidy the webpack setup")
  end

  describe "status questions (Peon answers, no new session)" do
    defp status(text) do
      p = Composer.parse(text, @projects)
      {p.action, p.status, p.project && p.project.name}
    end

    test "the word session alone does not start one" do
      assert status("What is the status on the latest session in amino-monorepo") ==
               {:status, :latest, "amino-monorepo"}
    end

    test "without a project it covers all of them" do
      assert status("what is the status of the latest sessions") == {:status, :overview, nil}
      assert status("what is the status of all sessions") == {:status, :overview, nil}
      assert status("anything waiting?") == {:status, :overview, nil}
    end

    test "routines too" do
      assert status("is the latest run of stripe reconcile done?") ==
               {:status, :latest, "stripe-reconcile"}
    end

    test "new/start a session still starts one" do
      assert read("start a new session in amino monorepo and check the status page") ==
               {:session, "amino-monorepo", nil, "check the status page"}
    end
  end

  test "prompt/1 puts the skill first" do
    assert Composer.prompt(%{skill: "review", task: "the last PR"}) == "/review the last PR"
    assert Composer.prompt(%{skill: "review", task: ""}) == "/review"
    assert Composer.prompt(%{skill: nil, task: "hi"}) == "hi"
  end

  describe "model and agent" do
    @catalog %{
      models: [
        %{value: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"},
        %{value: "anthropic/claude-sonnet-4-5", name: "Claude Sonnet 4.5"},
        %{value: "anthropic/claude-opus-4-1", name: "Claude Opus 4.1"},
        %{value: "github-copilot/claude-opus-4.1", name: "Claude Opus 4.1"},
        %{value: "openai/gpt-5", name: "GPT-5"},
        %{value: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash"}
      ],
      agents: ["build", "plan", "reviewer"],
      default_provider: "anthropic"
    }

    defp with_model(text) do
      p = Composer.parse(text, @projects, @catalog)
      {p.project && p.project.name, p.use_model && p.use_model.value, p.agent, p.task}
    end

    test "using a model, at the end or up front" do
      assert with_model("new session in chatos-web, fix the login button using opus") ==
               {"chatos-web", "anthropic/claude-opus-4-1", nil, "fix the login button"}

      assert with_model("@amino-monorepo with gpt-5, find why checkout fails on CI") ==
               {"amino-monorepo", "openai/gpt-5", nil, "find why checkout fails on CI"}
    end

    test "the newest match, versions written any way, the provider when named" do
      assert {_, "anthropic/claude-sonnet-4-5", _, _} =
               with_model("@chatos-web fix it with sonnet")

      assert {_, "anthropic/claude-sonnet-4", _, _} =
               with_model("@chatos-web fix it, model: claude sonnet 4")

      assert {_, "anthropic/claude-sonnet-4-5", _, _} =
               with_model("@chatos-web fix it on sonnet 4.5 model")

      assert {_, "github-copilot/claude-opus-4.1", _, _} =
               with_model("@chatos-web fix it using copilot opus")
    end

    test "an agent only with the word agent" do
      assert with_model("new session in chatos-web with the plan agent, plan the settings page") ==
               {"chatos-web", nil, "plan", "plan the settings page"}

      assert with_model("@chatos-web use reviewer agent with opus to review the auth change") ==
               {"chatos-web", "anthropic/claude-opus-4-1", "reviewer", "review the auth change"}
    end

    test "ordinary words stay in the task" do
      assert with_model("@chatos-web replace the banner with flash messages") ==
               {"chatos-web", nil, nil, "replace the banner with flash messages"}

      assert with_model("@chatos-web make a plan for the migration") ==
               {"chatos-web", nil, nil, "make a plan for the migration"}

      assert with_model("@chatos-web deploy on 5 servers") ==
               {"chatos-web", nil, nil, "deploy on 5 servers"}
    end

    test "no model on a run or a status question" do
      p = Composer.parse("run stripe-reconcile using opus", @projects, @catalog)
      assert {p.action, p.use_model} == {:run, nil}
    end

    test "resolve_model: unknown names are nil" do
      assert Composer.resolve_model("gpt-9", @catalog.models) == nil
      assert Composer.resolve_model("the", @catalog.models) == nil
    end
  end
end
