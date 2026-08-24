defmodule LLMProxy.HTTP.Routes.ModerationEndpoint do
  @moduledoc """
  Serves OpenAI-compatible moderation requests.
  """

  use Plug.Router

  require Logger

  alias LLMProxy.ConcurrencyLimiter
  alias LLMProxy.HTTP
  alias LLMProxy.HTTP.ErrorResponse
  alias LLMProxy.Plugs.{Auth, JSONBodyParser, QuotaCheck}
  alias LLMProxy.Providers.{HTTPResult, Result}
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
  plug(JSONBodyParser)
  plug(:match)
  plug(:dispatch)

  post "/" do
    {conn, trace_id} = Trace.ensure_conn(conn)

    case CreateRequest.parse(conn.body_params) do
      {:ok, attrs} ->
        moderate(conn, conn.assigns.api_key, attrs, trace_id)

      {:error, message} ->
        ErrorResponse.send_openai(conn, 400, "invalid_request_error", message)
    end
  end

  defp moderate(conn, api_key, %CreateRequest{} = attrs, trace_id) do
    case ConcurrencyLimiter.run(api_key, fn ->
           run_moderation(conn, api_key, attrs, trace_id)
         end) do
      {:error, {:limit_exceeded, _limit}} -> ErrorResponse.send_concurrency_limit_openai(conn)
      result -> result
    end
  end

  defp run_moderation(conn, api_key, %CreateRequest{} = attrs, trace_id) do
    Logger.info("Moderation from #{api_key.name} model=#{attrs.model}")

    case TokenPool.pick_token_by_kind("openai", "api-key", api_key.id) do
      {:ok, token} ->
        request_moderation(conn, attrs, token, trace_id)

      {:error, _reason} ->
        ErrorResponse.send_openai(conn, 503, "service_unavailable", "No OpenAI token available")
    end
  end

  defp request_moderation(conn, %CreateRequest{} = attrs, token, trace_id) do
    LLMProxy.Drain.track(:request, HTTP.request_meta(conn, trace_id, :moderations), fn ->
      req =
        HTTP.new(
          url: "https://api.openai.com/v1/moderations",
          headers: [{"authorization", "Bearer #{token.token}"}]
        )

      case post_moderation(req, attrs, trace_id) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          HTTP.send_json(conn, status, response)

        {:ok, %{status: status} = response} ->
          {:error, result} =
            HTTPResult.handle_response(token, Map.put_new(response, :headers, %{}))

          safe_error =
            ErrorResponse.safe_message(result.error, "Moderation provider request failed")

          Logger.error("Moderation provider error (#{status}): #{safe_error}")
          ErrorResponse.send_openai(conn, status, Result.client_error(result))

        {:error, exception} ->
          {:error, result} = HTTPResult.handle_exception(exception)
          safe_error = ErrorResponse.safe_message(result.error, "Moderation transport failed")
          Logger.error("Moderation transport error (#{result.status}): #{safe_error}")

          ErrorResponse.send_openai(conn, result.status, Result.client_error(result))
      end
    end)
    |> handle_drain_race(conn)
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

  defp handle_drain_race({:error, :draining}, conn) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "30")
    |> ErrorResponse.send_openai(
      503,
      "draining",
      "LLMProxy is draining and not accepting new requests"
    )
  end

  defp handle_drain_race(result, _conn), do: result

  match _ do
    ErrorResponse.send_openai(conn, 404, "not_found_error", "Not found")
  end
end
