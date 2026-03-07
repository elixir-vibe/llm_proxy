defmodule LLMProxyWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :llm_proxy

  @session_options [
    store: :cookie,
    key: "_llm_proxy_key",
    signing_salt: "llm_proxy_admin"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :phoenix,
    gzip: false,
    only: ~w(assets)

  plug Plug.Static,
    at: "/",
    from: :phoenix_live_view,
    gzip: false,
    only: ~w(assets)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    body_reader: {LLMProxy.CacheBodyReader, :read_body, []}

  plug Plug.Session, @session_options
  plug :route

  defp route(%{path_info: ["admin" | _]} = conn, _opts) do
    LLMProxyWeb.Router.call(conn, LLMProxyWeb.Router.init([]))
  end

  defp route(conn, _opts) do
    LLMProxy.Router.call(conn, LLMProxy.Router.init([]))
  end
end
