defmodule BeamcodeWeb.Router do
  use BeamcodeWeb, :router

  import BeamcodeWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BeamcodeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope
  end

  pipeline :mcp do
    plug :accepts, ["json"]
  end

  # MCP endpoint for the OpenCode server. Auth is the signed token in the path.
  scope "/mcp", BeamcodeWeb do
    pipe_through :mcp

    post "/:token", McpController, :handle
    get "/:token", McpController, :not_allowed
    delete "/:token", McpController, :not_allowed
  end

  # A project's files for the app's views. Auth is the signed token in the path.
  scope "/files", BeamcodeWeb do
    get "/:token/_query", FileController, :query
    post "/:token/_query", FileController, :query
    post "/:token/_act", FileController, :act
    get "/:token/*path", FileController, :show
  end

  scope "/", BeamcodeWeb do
    pipe_through [:browser, :redirect_if_user]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", BeamcodeWeb do
    pipe_through [:browser, :require_user]

    delete "/logout", SessionController, :delete

    # The Expo app's web build; it routes in the browser, so every path is the same page.
    get "/", AppController, :home
    get "/app", AppController, :index
    get "/app/*path", AppController, :index

    # Addresses from the old LiveView pages (bookmarks, shared links) open the same place in the app.
    get "/s/:id", AppController, :moved
    get "/p/:id", AppController, :moved
    get "/p/:id/:tab", AppController, :moved
    get "/:page", AppController, :moved
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:beamcode, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :require_user]

      live_dashboard "/dashboard", metrics: BeamcodeWeb.Telemetry
    end
  end
end
