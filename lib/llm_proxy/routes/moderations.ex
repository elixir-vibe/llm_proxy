defmodule LLMProxy.Routes.Moderations do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.TokenPool.Server, as: TokenPool

  plug Auth
  plug QuotaCheck
  plug :match
  plug :dispatch

  post "/" do
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"] || "omni-moderation-latest"

    Logger.info("Moderation from #{api_key.name} model=#{model}")

    case TokenPool.pick_token_by_kind("openai", "api-key", api_key.id) do
      {:ok, token} ->
        case Req.post(
               url: "https://api.openai.com/v1/moderations",
               headers: [{"authorization", "Bearer #{token.token}"}],
               json: %{input: body["input"], model: model}
             ) do
          {:ok, %{status: status, body: response}} ->
            send_json(conn, status, response)

          {:error, exception} ->
            Logger.error("Moderation error: #{Exception.message(exception)}")
            send_json(conn, 502, %{error: Exception.message(exception)})
        end

      {:error, reason} ->
        send_json(conn, 503, %{error: "No OpenAI token available: #{reason}"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
