defmodule BeamcodeWeb.AppController do
  @moduledoc """
  Serves the Expo app's web build (built from `mobile/` into `priv/static/app`
  by `mix assets.deploy`) at `/app`.

  Every `/app/...` page gets the same `index.html`, since the app routes in the
  browser. The logged-in user's socket token and the CSRF token go into its
  head, so the app connects with the web login (the session cookie) instead of
  asking for a password, and never stores the token itself.
  """
  use BeamcodeWeb, :controller
  alias BeamcodeWeb.AppToken

  def index(conn, _params) do
    case File.read(index_path()) do
      {:ok, html} ->
        user = conn.assigns.current_scope.user

        meta =
          ~s(<meta name="peon-token" content="#{escape(AppToken.sign(user))}">) <>
            ~s(<meta name="csrf-token" content="#{escape(get_csrf_token())}">)

        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, String.replace(html, "</head>", meta <> "</head>", global: false))

      {:error, _} ->
        send_resp(conn, 503, "The web app isn't built yet. Run `mix assets.deploy`.")
    end
  end

  def home(conn, _params), do: redirect(conn, to: ~p"/app")

  @tabs ~w(sessions chats skills schedules settings)
  @pages ~w(schedules settings new connectors models users)

  @doc "Addresses from the old LiveView pages, sent to the same page in the app."
  def moved(conn, %{"id" => id} = params) do
    cond do
      match?(["s", _], conn.path_info) -> redirect(conn, to: ~p"/app/session/#{id}")
      params["tab"] in @tabs -> redirect(conn, to: ~p"/app/project/#{id}?tab=#{params["tab"]}")
      true -> redirect(conn, to: ~p"/app/project/#{id}")
    end
  end

  def moved(conn, %{"page" => "inbox"}), do: redirect(conn, to: ~p"/app")
  def moved(conn, %{"page" => page}) when page in @pages, do: redirect(conn, to: "/app/#{page}")
  def moved(conn, _params), do: conn |> put_status(:not_found) |> text("Not found")

  defp index_path,
    do:
      Application.get_env(:beamcode, :app_index) ||
        Application.app_dir(:beamcode, "priv/static/app/index.html")

  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
