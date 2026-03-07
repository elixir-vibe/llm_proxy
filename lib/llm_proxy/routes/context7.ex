defmodule LLMProxy.Routes.Context7 do
  @moduledoc false

  use Plug.Router

  require Logger

  alias LLMProxy.Config
  alias LLMProxy.Plugs.{Auth, ServiceQuota}
  alias LLMProxy.Storage

  @context7_api_base "https://context7.com/api"
  @service "context7"

  plug Auth
  plug ServiceQuota, service: @service
  plug :match
  plug :dispatch

  get "/v2/libs/search", do: proxy(conn, "/v2/libs/search")
  get "/v2/context", do: proxy(conn, "/v2/context")

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp proxy(conn, endpoint) do
    api_key_value = Config.context7_api_key()

    if api_key_value == "" do
      send_json(conn, 500, %{error: "CONTEXT7_API_KEY not configured"})
    else
      do_proxy(conn, endpoint, api_key_value)
    end
  end

  defp do_proxy(conn, endpoint, api_key_value) do
    api_key = conn.assigns.api_key
    Logger.debug("Context7 request from #{api_key.name}: GET #{endpoint}")

    url =
      case conn.query_string do
        "" -> "#{@context7_api_base}#{endpoint}"
        qs -> "#{@context7_api_base}#{endpoint}?#{qs}"
      end

    req =
      Req.new(url: url, headers: [{"authorization", "Bearer #{api_key_value}"}])
      |> OpentelemetryReq.attach()

    response = Req.get!(req)

    track_service_usage(api_key, endpoint, response.status)

    response_body =
      case response.body do
        body when is_binary(body) -> body
        body -> Jason.encode!(body)
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(response.status, response_body)
  end

  defp track_service_usage(%{id: "master"}, _endpoint, _status), do: :ok

  defp track_service_usage(api_key, endpoint, status) when status in 200..299 do
    Storage.record_service_usage(%{
      key_id: api_key.id,
      service: @service,
      endpoint: endpoint,
      timestamp: DateTime.utc_now()
    })

    Logger.info("Context7 #{api_key.name} #{endpoint} completed")
  end

  defp track_service_usage(api_key, endpoint, status) do
    Logger.warning("Context7 #{api_key.name} #{endpoint} failed: #{status}")
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
