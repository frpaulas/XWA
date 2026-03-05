defmodule XwaWeb.Router do
  use XwaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {XwaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug XwaWeb.Plugs.FetchCurrentUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", XwaWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/graph/switch", GraphController, :switch

    # Local username/password auth
    get "/login", LocalSessionController, :new
    post "/login", LocalSessionController, :create
    get "/register", LocalSessionController, :register
    post "/register", LocalSessionController, :register_create
  end

  scope "/", XwaWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: {XwaWeb.Plugs.RequireAuthenticatedUser, :require_authenticated} do
      live "/sources", SourcesLive
      live "/graph", GraphLive
    end

    live_session :admin,
      on_mount: {XwaWeb.Plugs.RequireAdmin, :require_admin} do
      live "/admin/upload", AdminUploadLive
    end

    # Public read-only demos — each loads a specific user's graph without auth.
    live_session :demo1,
      on_mount: {XwaWeb.DemoMount, :demo1} do
      live "/demo1", GraphLive
    end

    live_session :demo2,
      on_mount: {XwaWeb.DemoMount, :demo2} do
      live "/demo2", GraphLive
    end
  end

  scope "/auth", XwaWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    delete "/logout", AuthController, :logout
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:xwa, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: XwaWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
