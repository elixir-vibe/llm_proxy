defmodule LLMProxy.HTTP.Routes.MessageEndpoint do
  @moduledoc """
  Anthropic Messages route adapter that preserves provider-native request and response shapes.
  """
  use Plug.Router

  require Logger

  alias LLMProxy.Accounting.UsageTracking
  alias LLMProxy.Actor
  alias LLMProxy.HTTP
  alias LLMProxy.HTTP.Routes.Passthrough
  alias LLMProxy.Plugs.{Auth, JSONBodyParser, QuotaCheck}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Provider
  alias LLMProxy.Providers.Result
  alias LLMProxy.Stream.{Event, Heartbeat, SSEWriter}
  alias LLMProxy.Telemetry
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxy.Trace
  alias LLMProxy.Usage

  plug(Auth)
  plug(QuotaCheck)
  plug(JSONBodyParser)
  plug(:match)
  plug(:dispatch)

  post "/" do
    handle_messages(conn)
  end

  match _ do
    send_error(conn, 404, "not_found_error", "Not found")
  end

  defp handle_messages(conn) do
    {conn, trace_id} = Trace.ensure_conn(conn)
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]

    case Request.parse(:anthropic_messages, body) do
      {:ok, request} ->
        Logger.debug(
          "Messages request from #{api_key.name} model=#{model} stream=#{request.stream || false}"
        )

        dispatch_provider(conn, request, api_key, trace_id)

      {:error, %Request.Error{} = error} ->
        send_error(conn, 400, error.code, error.message)
    end
  end

  defp dispatch_provider(conn, %Request{stream: true} = request, api_key, trace_id) do
    LLMProxy.Drain.track(:stream, HTTP.request_meta(conn, trace_id, :messages), fn ->
      case Provider.stream_native(request, Actor.from_api_key(api_key),
             route: :messages,
             trace_id: trace_id,
             api_name: "Messages API"
           ) do
        {:ok,
         %Result{kind: :stream, stream: stream, token: token, provider: provider, model: model}} ->
          handle_stream(conn, provider, stream, api_key, model, token, trace_id)

        {:error, reason} ->
          handle_provider_error(conn, reason)
      end
    end)
    |> handle_drain_race(conn)
  end

  defp dispatch_provider(conn, %Request{} = request, api_key, trace_id) do
    LLMProxy.Drain.track(:request, HTTP.request_meta(conn, trace_id, :messages), fn ->
      case Provider.call_native(request, Actor.from_api_key(api_key),
             route: :messages,
             trace_id: trace_id,
             api_name: "Messages API"
           ) do
        {:ok, %Result{kind: :response} = result} ->
          Passthrough.send_result(conn, result, api_key, trace_id, passthrough_result_handler())

        {:error, reason} ->
          handle_provider_error(conn, reason)
      end
    end)
    |> handle_drain_race(conn)
  end

  defp passthrough_result_handler do
    Passthrough.result_handler(&handle_non_stream/6, &handle_stream/7)
  end

  defp handle_provider_error(conn, reason) do
    Passthrough.send_error(
      conn,
      reason,
      Passthrough.error_handler(&send_error/4, &error_type/1, &mark_rate_limited_if_needed/1)
    )
  end

  defp handle_non_stream(conn, provider, response, api_key, model, trace_id) do
    usage = provider.extract_usage(response)
    UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
    HTTP.send_json(conn, 200, response)
  end

  defp handle_stream(conn, provider, stream, api_key, model, token, trace_id) do
    outcome = pipe_stream(conn, provider, stream, model, token, trace_id)

    case outcome do
      {:preflight_failure, conn, reason} ->
        error = Result.stream_failure(provider, model, token, reason)
        handle_provider_error(conn, {:provider, error})

      {:pending, conn, usage} ->
        conn = SSEWriter.start_sse(conn)
        UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
        conn

      {:started, conn, usage} ->
        UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
        conn
    end
  end

  defp pipe_stream(conn, provider, stream, model, token, trace_id) do
    telemetry = Telemetry.stream_context(provider.name(), model, trace_id)

    stream
    |> Heartbeat.wrap(telemetry: telemetry)
    |> Enum.reduce_while({:pending, conn, Usage.zero()}, fn
      %Heartbeat.Failure{reason: reason}, {:pending, conn, _usage} ->
        {:halt, {:preflight_failure, conn, reason}}

      %Heartbeat.Failure{reason: reason}, {:started, conn, usage} ->
        conn = write_stream_failure(conn, provider, model, token, reason)
        {:halt, {:started, conn, usage}}

      event, {:pending, conn, usage} ->
        conn = SSEWriter.start_sse(conn)
        reduce_stream_item(event, {:started, conn, usage}, provider)

      event, {:started, _conn, _usage} = state ->
        reduce_stream_item(event, state, provider)
    end)
  end

  defp reduce_stream_item(%Heartbeat{}, {:started, conn, usage}, _provider) do
    case SSEWriter.write_heartbeat(conn) do
      {:ok, conn} -> {:cont, {:started, conn, usage}}
      {:error, _reason} -> {:halt, {:started, conn, usage}}
    end
  end

  defp reduce_stream_item(%Event{} = event, {:started, conn, usage}, provider) do
    data = event.data
    usage = merge_stream_usage(usage, event, provider)

    case SSEWriter.write_named_event(conn, event.event || data["type"] || "unknown", data) do
      {:ok, conn} -> {:cont, {:started, conn, usage}}
      {:error, _reason} -> {:halt, {:started, conn, usage}}
    end
  end

  defp merge_stream_usage(usage, %Event{usage: event_usage}, _provider)
       when not is_nil(event_usage) do
    Usage.merge_max(usage, event_usage)
  end

  defp merge_stream_usage(
         usage,
         %Event{data: %{"type" => "message_start", "message" => %{"usage" => msg_usage}}},
         provider
       ) do
    event_usage = provider.extract_usage(%{"usage" => msg_usage})

    Usage.merge_max(usage, event_usage)
  end

  defp merge_stream_usage(
         usage,
         %Event{data: %{"type" => "message_delta", "usage" => delta_usage}},
         _provider
       )
       when is_map(delta_usage) do
    Usage.put_output_tokens(usage, delta_usage["output_tokens"] || 0)
  end

  defp merge_stream_usage(usage, _event, _provider), do: usage

  defp write_stream_failure(conn, provider, model, token, reason) do
    error = Result.stream_failure(provider, model, token, reason)
    error_event = %{"type" => "error", "error" => Result.client_error(error)}

    case SSEWriter.write_named_event(conn, "error", error_event) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp tracking_opts(provider, trace_id) do
    %{provider: provider.name(), metadata: %{"trace_id" => trace_id}}
  end

  defp mark_rate_limited_if_needed(%Result{status: 429, token: token}) when not is_nil(token) do
    TokenPool.mark_rate_limited(token)
  end

  defp mark_rate_limited_if_needed(_result), do: :ok

  defp error_type(429), do: "rate_limit_error"
  defp error_type(401), do: "authentication_error"
  defp error_type(400), do: "invalid_request_error"
  defp error_type(_), do: "api_error"

  defp handle_drain_race({:error, :draining}, conn) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "30")
    |> send_error(503, "draining", "LLMProxy is draining and not accepting new requests")
  end

  defp handle_drain_race(result, _conn), do: result

  defp send_error(conn, status, type, message) do
    HTTP.send_json(conn, status, %{type: "error", error: %{type: type, message: message}})
  end
end
