defmodule LLMProxy.Web.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {LLMProxy.Web.Layouts, :root})
  end

  scope "/admin", LLMProxy.Web do
    pipe_through(:browser)

    get("/login", LoginController, :index)
    post("/login", LoginController, :create)
    get("/logout", LoginController, :logout)

    live_session :admin, on_mount: {LLMProxy.Web.AdminAuth, :require_admin} do
      live("/", DashboardLive)
      live("/keys", KeysLive)
      live("/tokens", TokensLive)
      live("/messages", MessagesLive)
      live("/traces", TracesLive)
      live("/models", ModelsLive)
    end
  end
end
