defmodule BeamcodeWeb.SessionControllerTest do
  use BeamcodeWeb.ConnCase, async: true

  test "first visit creates the admin and opens the app", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Create the admin account"

    conn =
      post(build_conn(), ~p"/login", %{
        "user" => %{"username" => "aksel", "password" => "password123"}
      })

    assert redirected_to(conn) == ~p"/app"
    assert Beamcode.Accounts.get_user_by_username("aksel").admin
  end

  test "wrong password shows an error", %{conn: conn} do
    user_fixture(%{"username" => "aksel"})

    conn =
      post(conn, ~p"/login", %{"user" => %{"username" => "aksel", "password" => "nope-nope"}})

    assert html_response(conn, 200) =~ "Wrong username or password"
  end

  test "logging in goes back to the page asked for", %{conn: conn} do
    user_fixture(%{"username" => "aksel", "password" => "password123"})
    conn = get(conn, ~p"/app/schedules")
    assert redirected_to(conn) == ~p"/login"

    conn =
      post(conn, ~p"/login", %{"user" => %{"username" => "aksel", "password" => "password123"}})

    assert redirected_to(conn) == "/app/schedules"
  end

  test "logged in, the login page sends you to the app", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/login")
    assert redirected_to(conn) == ~p"/app"
  end
end
