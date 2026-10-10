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

  test "no project named: the chat project, and suggestions" do
    parsed = Composer.parse("how do I write a haiku?", @projects)
    assert {:chat, "general", nil, "how do I write a haiku?"} = read("how do I write a haiku?")

    assert Enum.map(Composer.suggestions(parsed, @projects), & &1.name) ==
             ~w(amino-monorepo chatos-web general)
  end

  test "names only match whole words; system projects are not targets" do
    assert {:chat, "general", nil, _} = read("tidy the webpack setup")
  end

  test "prompt/1 puts the skill first" do
    assert Composer.prompt(%{skill: "review", task: "the last PR"}) == "/review the last PR"
    assert Composer.prompt(%{skill: "review", task: ""}) == "/review"
    assert Composer.prompt(%{skill: nil, task: "hi"}) == "hi"
  end
end
