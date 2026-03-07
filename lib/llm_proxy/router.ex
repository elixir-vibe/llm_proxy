defmodule LLMProxy.Router do
  use Plug.Router

  alias LLMProxy.Routes.Dynamic

  plug Plug.Logger
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    body_reader: {LLMProxy.CacheBodyReader, :read_body, []}

  plug :dispatch

  # Health check — no auth
  get "/health" do
    send_json(conn, 200, %{status: "ok", version: "0.1.0"})
  end

  # Models — no auth
  get "/v1/models" do
    models = LLMProxy.Providers.Registry.all_models()
    send_json(conn, 200, %{object: "list", data: models})
  end

  get "/models" do
    models = LLMProxy.Providers.Registry.all_models()
    send_json(conn, 200, %{object: "list", data: models})
  end

  # Forward to sub-routers
  forward "/keys", to: LLMProxy.Routes.Keys
  forward "/tokens", to: LLMProxy.Routes.Tokens
  forward "/stats", to: LLMProxy.Routes.Stats
  forward "/admin", to: LLMProxy.Routes.Stats
  forward "/setup", to: LLMProxy.Routes.Setup
  forward "/v1/chat", to: LLMProxy.Routes.Chat
  forward "/chat", to: LLMProxy.Routes.Chat
  forward "/v1/moderations", to: LLMProxy.Routes.Moderations
  forward "/moderations", to: LLMProxy.Routes.Moderations
  forward "/v1/exa", to: LLMProxy.Routes.Exa
  forward "/v1/context7", to: LLMProxy.Routes.Context7
  forward "/providers", to: LLMProxy.Routes.ProviderUsage

  # Dynamic routes registered by optional packages (e.g., llm_proxy_private)
  match _ do
    case Dynamic.dispatch(conn) do
      nil -> send_json(conn, 404, %{error: "Not found"})
      conn -> conn
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
