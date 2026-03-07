defmodule LlmProxy.Router do
  use Plug.Router

  plug Plug.Logger
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    body_reader: {LlmProxy.CacheBodyReader, :read_body, []}

  plug :dispatch

  # Health check — no auth
  get "/health" do
    send_json(conn, 200, %{status: "ok", version: "0.1.0"})
  end

  # Models — no auth
  get "/v1/models" do
    models = LlmProxy.Providers.Registry.all_models()
    send_json(conn, 200, %{object: "list", data: models})
  end

  get "/models" do
    models = LlmProxy.Providers.Registry.all_models()
    send_json(conn, 200, %{object: "list", data: models})
  end

  # Forward to sub-routers
  forward "/keys", to: LlmProxy.Routes.Keys
  forward "/tokens", to: LlmProxy.Routes.Tokens
  forward "/stats", to: LlmProxy.Routes.Stats
  forward "/admin", to: LlmProxy.Routes.Stats
  forward "/setup", to: LlmProxy.Routes.Setup
  forward "/v1/chat", to: LlmProxy.Routes.Chat
  forward "/chat", to: LlmProxy.Routes.Chat
  forward "/v1/exa", to: LlmProxy.Routes.Exa
  forward "/v1/context7", to: LlmProxy.Routes.Context7
  forward "/providers", to: LlmProxy.Routes.ProviderUsage

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
