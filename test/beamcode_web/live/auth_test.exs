defmodule BeamcodeWeb.AuthTest do
  use BeamcodeWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "first visit creates the admin", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Create the admin account"

    conn =
      post(build_conn(), ~p"/login", %{
        "user" => %{"username" => "aksel", "password" => "password123"}
      })

    assert redirected_to(conn) == ~p"/"
    assert Beamcode.Accounts.get_user_by_username("aksel").admin
  end

  test "wrong password shows an error", %{conn: conn} do
    user_fixture(%{"username" => "aksel"})

    conn =
      post(conn, ~p"/login", %{"user" => %{"username" => "aksel", "password" => "nope-nope"}})

    assert html_response(conn, 200) =~ "Wrong username or password"
  end

  test "signed-out users are sent to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/inbox")
  end

  test "admins see users; others are redirected", %{conn: conn} do
    admin = user_fixture()
    member = user_fixture()

    {:ok, view, _} = conn |> log_in_user(admin) |> live(~p"/users")
    assert has_element?(view, "#user-form")

    assert {:error, {:redirect, %{to: "/"}}} =
             build_conn() |> log_in_user(member) |> live(~p"/users")
  end

  test "admin creates a user", %{conn: conn} do
    admin = user_fixture()
    {:ok, view, _} = conn |> log_in_user(admin) |> live(~p"/users")

    view
    |> form("#user-form", user: %{username: "marte", password: "password456"})
    |> render_submit()

    assert has_element?(view, "#users", "marte")
    refute Beamcode.Accounts.get_user_by_username("marte").admin
  end

  test "shortcuts are editable and resettable", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/settings")
    assert has_element?(view, "#key-model_list[value='<leader>m']")

    view |> form("#keys-form", keys: %{model_list: "ctrl+m"}) |> render_submit()
    assert Beamcode.Accounts.get_user(user.id).keybinds == %{"model_list" => "ctrl+m"}
    assert has_element?(view, "#app-shell[data-keybinds*='ctrl+m']")

    view |> element("#reset-keys") |> render_click()
    assert Beamcode.Accounts.get_user(user.id).keybinds == %{}
  end

  test "keymap and prefix are saved without losing shortcuts", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/settings")
    assert has_element?(view, "#app-shell[data-keymap='tmux'][data-prefix='ctrl+b']")
    assert has_element?(view, "#status-line")
    assert has_element?(view, "#kb-help")

    view |> form("#keys-form", keys: %{model_list: "ctrl+m"}) |> render_submit()

    view
    |> form("#prefs-form", prefs: %{keymap: "standard", prefix: "ctrl+a", status_line: "false"})
    |> render_submit()

    assert Beamcode.Accounts.get_user(user.id).keybinds == %{
             "model_list" => "ctrl+m",
             "keymap" => "standard",
             "prefix" => "ctrl+a",
             "status_line" => false
           }

    assert has_element?(view, "#app-shell[data-keymap='standard'][data-prefix='ctrl+a']")
    refute has_element?(view, "#status-line")

    view |> element("#reset-keys") |> render_click()
    assert Beamcode.Accounts.get_user(user.id).keybinds["keymap"] == "standard"
  end

  test "palette opens in switch mode without actions", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/inbox")
    render_hook(view, "palette_open", %{"mode" => "switch"})
    assert has_element?(view, "#palette-input[placeholder^='Switch to']")
    refute has_element?(view, "#palette-items", "New project")

    render_hook(view, "palette_close", %{})
    render_hook(view, "palette_open", %{})
    assert has_element?(view, "#palette-items", "New project")
  end

  test "home offers to create a project when there is none", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/")
    assert has_element?(view, "#home-new-code")
    assert has_element?(view, "#sidebar")
  end
end
