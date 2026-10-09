defmodule BeamcodeWeb.NewProjectTest do
  use BeamcodeWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "the GitHub token field shows for github.com URLs only", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/new?kind=code")
    refute has_element?(view, "#github-token-field")

    view
    |> form("#project-form", project: %{name: "app", source: "/srv/repos/app"})
    |> render_change()

    refute has_element?(view, "#github-token-field")

    view
    |> form("#project-form", project: %{source: "git@github.com:org/app.git"})
    |> render_change()

    assert has_element?(view, "#github-token-field input[type=password]")

    view
    |> form("#project-form", project: %{github_token: "github_pat_x"})
    |> render_change()

    assert has_element?(view, "#will-create", "https://github.com/org/app.git")
  end
end
