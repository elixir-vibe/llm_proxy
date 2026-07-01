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
  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Provider
  alias LLMProxy.Providers.Result
  alias LLMProxy.Stream.{Event, SSEWriter}
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxy.Trace
  alias LLMProxy.Usage

  plug(Auth)
  plug(QuotaCheck)
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
    LLMProxy.Drain.track(:stream, request_meta(conn, trace_id, :messages), fn ->
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
    LLMProxy.Drain.track(:request, request_meta(conn, trace_id, :messages), fn ->
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
    conn = SSEWriter.start_sse(conn)
    {conn, usage} = pipe_stream(conn, provider, stream, token)
    UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
    conn
  end

  defp pipe_stream(conn, provider, stream, token) do
    zero_usage = Usage.zero()

    try do
      Enum.reduce_while(stream, {conn, zero_usage}, fn %Event{} = event, {conn, usage} ->
        data = event.data
        usage = merge_stream_usage(usage, event, provider)

        case SSEWriter.write_named_event(conn, event.event || data["type"] || "unknown", data) do
          {:ok, conn} -> {:cont, {conn, usage}}
          {:error, _reason} -> {:halt, {conn, usage}}
        end
      end)
    rescue
      e in [RuntimeError, Jason.DecodeError, Protocol.UndefinedError] ->
        handle_stream_error(conn, e, token)
        {conn, zero_usage}
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

  defp handle_stream_error(conn, error, token) do
    error_msg = Exception.message(error)

    is_rate_limit =
      String.contains?(error_msg, "429") || String.contains?(error_msg, "rate_limit")

    if is_rate_limit && token, do: TokenPool.mark_rate_limited(token)
    Logger.error("Stream error: #{error_msg}")

    error_event = %{
      "type" => "error",
      "error" => %{
        "type" => if(is_rate_limit, do: "rate_limit_error", else: "api_error"),
        "message" => error_msg
      }
    }

    SSEWriter.write_named_event(conn, "error", error_event)
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

  defp request_meta(conn, trace_id, route) do
    %{method: conn.method, path: conn.request_path, request_id: trace_id, route: route}
  end

  defp send_error(conn, status, type, message) do
    HTTP.send_json(conn, status, %{type: "error", error: %{type: type, message: message}})
  end
end
