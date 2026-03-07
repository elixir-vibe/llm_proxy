defmodule LLMProxy.Routes.Exa do
  use Plug.Router

  require Logger

  alias LLMProxy.Config
  alias LLMProxy.Plugs.Auth
  alias LLMProxy.Storage

  @exa_api_base "https://api.exa.ai"
  @service "exa"

  plug Auth
  plug :check_service_quota
  plug :match
  plug :dispatch

  post "/search", do: proxy(conn, "/search")
  post "/contents", do: proxy(conn, "/contents")
  post "/findSimilar", do: proxy(conn, "/findSimilar")
  post "/answer", do: proxy(conn, "/answer")

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp check_service_quota(conn, _opts) do
    api_key = conn.assigns.api_key

    case Storage.check_service_quota(api_key, @service) do
      :ok -> conn
      {:error, reason} -> conn |> send_json(429, %{error: reason}) |> halt()
    end
  end

  defp proxy(conn, endpoint) do
    api_key = conn.assigns.api_key
    exa_key = Config.exa_api_key()

    if exa_key == "" do
      send_json(conn, 500, %{error: "EXA_API_KEY not configured"})
    else
      Logger.debug("EXA request from #{api_key.name}: POST #{endpoint}")
      raw_body = conn.private[:raw_body] || Jason.encode!(conn.body_params)

      response =
        Req.post!("#{@exa_api_base}#{endpoint}",
          body: raw_body,
          headers: [
            {"content-type", "application/json"},
            {"x-api-key", exa_key}
          ]
        )

      if response.status in 200..299 do
        if api_key.id != "master" do
          Storage.record_service_usage(%{
            key_id: api_key.id,
            service: @service,
            endpoint: endpoint,
            timestamp: DateTime.utc_now()
          })
        end

        Logger.info("EXA #{api_key.name} #{endpoint} completed")
      else
        Logger.warning("EXA #{api_key.name} #{endpoint} failed: #{response.status}")
      end

      response_body =
        case response.body do
          body when is_binary(body) -> body
          body -> Jason.encode!(body)
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(response.status, response_body)
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
