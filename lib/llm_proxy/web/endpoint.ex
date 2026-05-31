defmodule LLMProxy.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :llm_proxy

  @session_options [
    store: :cookie,
    key: "_llm_proxy_key",
    signing_salt: "llm_proxy_admin"
  ]

  @code_reloading Application.compile_env(:llm_proxy, __MODULE__)[:code_reloader] == true

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/",
    from: :llm_proxy,
    gzip: not @code_reloading,
    only: ~w(assets)
  )

  if @code_reloading do
    plug(Phoenix.CodeReloader)
    plug(Volt.DevServer, root: "assets")
  end

  plug(Plug.RequestId, assign_as: :request_id)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(:route)

  defp route(%{path_info: ["admin" | _]} = conn, _opts) do
    LLMProxy.Web.Router.call(conn, LLMProxy.Web.Router.init([]))
  end

  defp route(conn, _opts) do
    LLMProxy.HTTP.Router.call(conn, LLMProxy.HTTP.Router.init([]))
  end
end
