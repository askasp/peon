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

  scope "/", BeamcodeWeb do
    pipe_through [:browser, :redirect_if_user]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", BeamcodeWeb do
    pipe_through [:browser, :require_user]

    delete "/logout", SessionController, :delete

    live_session :app,
      on_mount: [{BeamcodeWeb.UserAuth, :ensure_authenticated}, BeamcodeWeb.Shell] do
      live "/", HomeLive
      live "/new", NewProjectLive
      live "/p/:id", ProjectLive, :sessions
      live "/p/:id/chats", ProjectLive, :chats
      live "/p/:id/skills", ProjectLive, :skills
      live "/p/:id/schedules", ProjectLive, :schedules
      live "/p/:id/settings", ProjectLive, :settings
      live "/s/:id", SessionLive
      live "/inbox", InboxLive
      live "/schedules", SchedulesLive
      live "/settings", SettingsLive
    end

    live_session :admin,
      on_mount: [
        {BeamcodeWeb.UserAuth, :ensure_authenticated},
        {BeamcodeWeb.UserAuth, :require_admin},
        BeamcodeWeb.Shell
      ] do
      live "/connectors", ConnectorsLive
      live "/models", ModelsLive
      live "/users", UsersLive
    end
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
