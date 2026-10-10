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
end
