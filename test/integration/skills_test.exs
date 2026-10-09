defmodule BeamcodeWeb.Integration.SkillsTest do
  @moduledoc """
  Runs against a real OpenCode server. Excluded by default; run with

      OPENCODE_TEST_URL=http://127.0.0.1:4199 OPENCODE_TEST_PASSWORD=... \\
        OPENCODE_TEST_DIR=/some/existing/dir mix test --only opencode
  """
  use BeamcodeWeb.ConnCase
  import Phoenix.LiveViewTest

  @moduletag :opencode

  setup do
    prev = Application.get_env(:beamcode, :opencode)

    Application.put_env(:beamcode, :opencode,
      url: System.fetch_env!("OPENCODE_TEST_URL"),
      password: System.get_env("OPENCODE_TEST_PASSWORD")
    )

    on_exit(fn -> Application.put_env(:beamcode, :opencode, prev) end)

    dir =
      Path.join(
        System.fetch_env!("OPENCODE_TEST_DIR"),
        "skills-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, project} =
      Beamcode.Projects.insert_project(
        %{name: "it", kind: "chat", directory: dir, scope: "team"},
        nil
      )

    %{project: project, dir: dir}
  end

  test "create a skill from the Skills tab", %{conn: conn, project: project, dir: dir} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/p/#{project.id}/skills")
    assert has_element?(view, "#tab-skills")

    view |> element("#new-skill") |> render_click()
    view |> form("#new-skill-form", skill: %{name: "digest"}) |> render_submit()

    assert File.read!(Path.join(dir, ".opencode/skill/digest/SKILL.md")) =~ "name: digest"
    assert has_element?(view, "#file--opencode-skill-digest-SKILL-md", "/digest")
    # OpenCode reloads the folder in the background.
    assert Enum.any?(1..20, fn _ ->
             Process.sleep(250)

             match?({:ok, list} when is_list(list), Beamcode.Opencode.skills(dir)) and
               Enum.any?(elem(Beamcode.Opencode.skills(dir), 1), &(&1["name"] == "digest"))
           end),
           "OpenCode should see the new skill"

    view |> element("#new-skill") |> render_click()

    assert view |> form("#new-skill-form", skill: %{name: "Bad Name"}) |> render_submit() =~
             "lowercase"
  end
end
