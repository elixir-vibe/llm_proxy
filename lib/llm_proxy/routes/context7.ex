defmodule LLMProxy.Routes.Context7 do
  use Plug.Router

  require Logger

  alias LLMProxy.Config
  alias LLMProxy.Plugs.Auth
  alias LLMProxy.Storage

  @context7_api_base "https://context7.com/api"
  @service "context7"

  plug Auth
  plug :check_service_quota
  plug :match
  plug :dispatch

  get "/v2/libs/search", do: proxy(conn, "/v2/libs/search")
  get "/v2/context", do: proxy(conn, "/v2/context")

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
    api_key_value = Config.context7_api_key()

    if api_key_value == "" do
      send_json(conn, 500, %{error: "CONTEXT7_API_KEY not configured"})
    else
      Logger.debug("Context7 request from #{api_key.name}: GET #{endpoint}")

      url =
        case conn.query_string do
          "" -> "#{@context7_api_base}#{endpoint}"
          qs -> "#{@context7_api_base}#{endpoint}?#{qs}"
        end

      response =
        Req.get!(url,
          headers: [
            {"authorization", "Bearer #{api_key_value}"}
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

        Logger.info("Context7 #{api_key.name} #{endpoint} completed")
      else
        Logger.warning("Context7 #{api_key.name} #{endpoint} failed: #{response.status}")
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
