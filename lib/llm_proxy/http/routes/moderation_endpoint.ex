defmodule LLMProxy.HTTP.Routes.ModerationEndpoint do
  @moduledoc """
  Serves OpenAI-compatible moderation requests.
  """

  use Plug.Router

  require Logger

  alias LLMProxy.HTTP
  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Telemetry
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxy.Trace

  defmodule CreateRequest do
    @moduledoc """
    Parsed moderation request body.
    """

    @default_model "omni-moderation-latest"

    defstruct [:input, :model]

    @type t :: %__MODULE__{input: String.t() | [String.t()] | map() | [map()], model: String.t()}

    @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
    def parse(%{"input" => input} = body) when is_binary(input) and input != "" do
      {:ok, %__MODULE__{input: input, model: model(body)}}
    end

    def parse(%{"input" => [_ | _] = input} = body) do
      {:ok, %__MODULE__{input: input, model: model(body)}}
    end

    def parse(%{"input" => %{} = input} = body) do
      {:ok, %__MODULE__{input: input, model: model(body)}}
    end

    def parse(_body), do: {:error, "input is required"}

    defp model(%{"model" => model}) when is_binary(model) and model != "", do: model
    defp model(_body), do: @default_model
  end

  plug(Auth)
  plug(QuotaCheck)
  plug(:match)
  plug(:dispatch)

  post "/" do
    {conn, trace_id} = Trace.ensure_conn(conn)

    case CreateRequest.parse(conn.body_params) do
      {:ok, attrs} ->
        moderate(conn, conn.assigns.api_key, attrs, trace_id)

      {:error, message} ->
        send_json(conn, 400, %{error: message})
    end
  end

  defp moderate(conn, api_key, %CreateRequest{} = attrs, trace_id) do
    Logger.info("Moderation from #{api_key.name} model=#{attrs.model}")

    case TokenPool.pick_token_by_kind("openai", "api-key", api_key.id) do
      {:ok, token} ->
        request_moderation(conn, attrs, token, trace_id)

      {:error, reason} ->
        send_json(conn, 503, %{error: "No OpenAI token available: #{reason}"})
    end
  end

  defp request_moderation(conn, %CreateRequest{} = attrs, token, trace_id) do
    req =
      HTTP.new(
        url: "https://api.openai.com/v1/moderations",
        headers: [{"authorization", "Bearer #{token.token}"}]
      )

    case post_moderation(req, attrs, trace_id) do
      {:ok, %{status: status, body: response}} ->
        send_json(conn, status, response)

      {:error, exception} ->
        Logger.error("Moderation error: #{Exception.message(exception)}")
        send_json(conn, 502, %{error: Exception.message(exception)})
    end
  end

  defp post_moderation(req, %CreateRequest{} = attrs, trace_id) do
    Telemetry.with_provider_span(
      "openai",
      attrs.model,
      :moderations,
      fn -> Req.post(req, json: %{input: attrs.input, model: attrs.model}) end,
      %{"llm_proxy.trace_id" => trace_id}
    )
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
