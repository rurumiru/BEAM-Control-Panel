defmodule BeamPanelWeb.Router do
  use BeamPanelWeb, :router

  import BeamPanelWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BeamPanelWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug BeamPanelWeb.ApiAuth
  end

  pipeline :setup_required do
    plug :require_setup
  end

  pipeline :guest_only do
    plug :redirect_if_user_is_authenticated
  end

  pipeline :authenticated do
    plug :require_authenticated_user
  end

  ## ------------------------------------------------------------------ public

  scope "/", BeamPanelWeb do
    pipe_through [:browser]

    get "/setup", SetupController, :new
    post "/setup", SetupController, :create
  end

  scope "/", BeamPanelWeb do
    pipe_through [:browser, :setup_required, :guest_only]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", BeamPanelWeb do
    pipe_through [:browser]

    delete "/logout", SessionController, :delete
    get "/logout", SessionController, :delete
  end

  ## --------------------------------------------------------------- protected

  scope "/", BeamPanelWeb do
    pipe_through [:browser, :setup_required, :authenticated]

    live_session :authenticated,
      on_mount: [{BeamPanelWeb.UserAuth, :ensure_authenticated}, BeamPanelWeb.Nav],
      layout: {BeamPanelWeb.Layouts, :app} do
      live "/", DashboardLive, :index

      live "/servers", ServerLive.Index, :index
      live "/servers/new", ServerLive.Index, :new
      live "/servers/:id/edit", ServerLive.Index, :edit
      live "/servers/:id", ServerLive.Show, :show
      live "/servers/:id/provision", ServerLive.Provision, :index
      live "/servers/:id/services", ServerLive.Services, :index
      live "/servers/:id/discover", ServerLive.Discover, :index

      live "/projects", ProjectLive.Index, :index
      live "/projects/new", ProjectLive.Index, :new
      live "/projects/:id/edit", ProjectLive.Index, :edit
      live "/projects/:id", ProjectLive.Show, :show
      live "/projects/:id/env", ProjectLive.Env, :index
      live "/projects/:id/logs", ProjectLive.Logs, :index
      live "/projects/:id/beam", ProjectLive.Beam, :index

      live "/deployments", DeploymentLive.Index, :index
      live "/deployments/:id", DeploymentLive.Show, :show

      live "/provisioning/:id", ServerLive.ProvisionRun, :show

      live "/cluster", ClusterLive, :index
      live "/audit", AuditLive, :index

      live "/settings", SettingsLive.Profile, :index
      live "/settings/tokens", SettingsLive.Tokens, :index
      live "/settings/users", SettingsLive.Users, :index
      live "/settings/notifications", SettingsLive.Notifications, :index
    end
  end

  ## --------------------------------------------------------------------- API

  scope "/api/v1", BeamPanelWeb.Api, as: :api do
    pipe_through [:api, :api_authenticated]

    get "/status", StatusController, :show

    resources "/servers", ServerController, only: [:index, :show]
    get "/servers/:id/metrics", ServerController, :metrics
    post "/servers/:id/check", ServerController, :check

    resources "/projects", ProjectController, only: [:index, :show]
    post "/projects/:id/deploy", ProjectController, :deploy
    post "/projects/:id/restart", ProjectController, :restart
    post "/projects/:id/rollback", ProjectController, :rollback

    resources "/deployments", DeploymentController, only: [:index, :show]
  end

  ## ------------------------------------------------------------- dev routes

  if Application.compile_env(:beam_panel, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BeamPanelWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
