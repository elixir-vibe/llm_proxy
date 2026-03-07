defmodule LLMProxy.Routes.Exa do
  @moduledoc false

  use Plug.Router

  require Logger

  alias LLMProxy.Config
  alias LLMProxy.Plugs.{Auth, ServiceQuota}
  alias LLMProxy.Storage

  @exa_api_base "https://api.exa.ai"
  @service "exa"

  plug Auth
  plug ServiceQuota, service: @service
  plug :match
  plug :dispatch

  post "/search", do: proxy(conn, "/search")
  post "/contents", do: proxy(conn, "/contents")
  post "/findSimilar", do: proxy(conn, "/findSimilar")
  post "/answer", do: proxy(conn, "/answer")

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp proxy(conn, endpoint) do
    exa_key = Config.exa_api_key()

    if exa_key == "" do
      send_json(conn, 500, %{error: "EXA_API_KEY not configured"})
    else
      do_proxy(conn, endpoint, exa_key)
    end
  end

  defp do_proxy(conn, endpoint, exa_key) do
    api_key = conn.assigns.api_key
    Logger.debug("EXA request from #{api_key.name}: POST #{endpoint}")
    raw_body = conn.private[:raw_body] || Jason.encode!(conn.body_params)

    req =
      Req.new(url: "#{@exa_api_base}#{endpoint}", headers: [{"content-type", "application/json"}, {"x-api-key", exa_key}])
      |> OpentelemetryReq.attach()

    response = Req.post!(req, body: raw_body)

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

    Logger.info("EXA #{api_key.name} #{endpoint} completed")
  end

  defp track_service_usage(api_key, endpoint, status) do
    Logger.warning("EXA #{api_key.name} #{endpoint} failed: #{status}")
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
