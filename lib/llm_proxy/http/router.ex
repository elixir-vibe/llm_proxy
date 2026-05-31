defmodule LLMProxy.HTTP.Router do
  @moduledoc false

  use Plug.Router

  alias LLMProxy.HTTP.Routes.Dynamic
  alias LLMProxy.HTTP.Routes.Helpers

  plug(:match)
  plug(:dispatch)

  get "/health" do
    Helpers.send_json(conn, 200, %{status: "ok", version: "0.1.0"})
  end

  forward("/v1/models", to: LLMProxy.HTTP.Routes.Models)
  forward("/models", to: LLMProxy.HTTP.Routes.Models)
  forward("/keys", to: LLMProxy.HTTP.Routes.Keys)
  forward("/tokens", to: LLMProxy.HTTP.Routes.Tokens)
  forward("/stats", to: LLMProxy.HTTP.Routes.Stats)
  forward("/v1/chat", to: LLMProxy.HTTP.Routes.Chat)
  forward("/chat", to: LLMProxy.HTTP.Routes.Chat)
  forward("/v1/messages", to: LLMProxy.HTTP.Routes.Messages)
  forward("/v1/responses", to: LLMProxy.HTTP.Routes.Responses)
  forward("/v1/moderations", to: LLMProxy.HTTP.Routes.Moderations)
  forward("/moderations", to: LLMProxy.HTTP.Routes.Moderations)

  match _ do
    case Dynamic.dispatch(conn) do
      nil -> Helpers.send_json(conn, 404, %{error: "Not found"})
      conn -> conn
    end
  end
end
