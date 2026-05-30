defmodule LLMProxy.Routes.Moderations do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.HTTP
  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Routes.Moderations.Params
  alias LLMProxy.TokenPool.Server, as: TokenPool

  plug(Auth)
  plug(QuotaCheck)
  plug(:match)
  plug(:dispatch)

  post "/" do
    case Params.parse_create(conn.body_params) do
      {:ok, attrs} ->
        moderate(conn, conn.assigns.api_key, attrs)

      {:error, message} ->
        send_json(conn, 400, %{error: message})
    end
  end

  defp moderate(conn, api_key, %Params.Create{} = attrs) do
    Logger.info("Moderation from #{api_key.name} model=#{attrs.model}")

    case TokenPool.pick_token_by_kind("openai", "api-key", api_key.id) do
      {:ok, token} ->
        req =
          HTTP.new(
            url: "https://api.openai.com/v1/moderations",
            headers: [{"authorization", "Bearer #{token.token}"}]
          )

        case Req.post(req, json: %{input: attrs.input, model: attrs.model}) do
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
