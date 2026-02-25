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
