defmodule LLMProxy.HTTP.Routes.Responses do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.Accounting.UsageTracking
  alias LLMProxy.Actor
  alias LLMProxy.HTTP.Routes.{Helpers, NativeErrors, NativeResults}
  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Provider
  alias LLMProxy.Providers.Result
  alias LLMProxy.Stream.{Event, SSEWriter}
  alias LLMProxy.TokenPool.RateLimit
  alias LLMProxy.Trace
  alias LLMProxy.Usage

  plug(Auth)
  plug(QuotaCheck)
  plug(:match)
  plug(:dispatch)

  post "/" do
    handle_responses(conn)
  end

  match _ do
    send_error(conn, 404, "not_found_error", "Not found")
  end

  defp handle_responses(conn) do
    {conn, trace_id} = Trace.ensure_conn(conn)
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]

    case Request.parse(:openai_responses, body) do
      {:ok, request} ->
        Logger.debug(
          "Responses request from #{api_key.name} model=#{model} stream=#{responses_stream?(request)}"
        )

        dispatch_provider(conn, normalize_stream(request), api_key, trace_id)

      {:error, %Request.Error{} = error} ->
        send_error(conn, 400, error.code, error.message)
    end
  end

  defp normalize_stream(%Request{stream: false} = request), do: request

  defp normalize_stream(%Request{} = request),
    do: %{request | body: Map.put(request.body, "stream", true), stream: true}

  defp responses_stream?(%Request{} = request), do: normalize_stream(request).stream

  defp dispatch_provider(conn, %Request{stream: true} = request, api_key, trace_id) do
    case Provider.stream_native(request, Actor.from_api_key(api_key),
           route: :responses,
           trace_id: trace_id,
           api_name: "Responses API"
         ) do
      {:ok, %Result{kind: :stream} = result} ->
        NativeResults.handle(conn, result, api_key, trace_id, native_handlers())

      {:error, reason} ->
        handle_provider_error(conn, reason)
    end
  end

  defp dispatch_provider(conn, %Request{} = request, api_key, trace_id) do
    case Provider.call_native(request, Actor.from_api_key(api_key),
           route: :responses,
           trace_id: trace_id,
           api_name: "Responses API"
         ) do
      {:ok, %Result{kind: :response} = result} ->
        NativeResults.handle(conn, result, api_key, trace_id, native_handlers())

      {:error, reason} ->
        handle_provider_error(conn, reason)
    end
  end

  defp native_handlers do
    %{non_stream: &handle_non_stream/6, stream: &handle_stream/7}
  end

  defp handle_provider_error(conn, reason) do
    NativeErrors.send(
      conn,
      reason,
      &send_error/4,
      fn _status -> "api_error" end,
      &mark_rate_limited_if_needed/1
    )
  end

  defp mark_rate_limited_if_needed(%Result{status: 429, token: token}) when not is_nil(token) do
    RateLimit.mark_rate_limited(token)
  end

  defp mark_rate_limited_if_needed(_result), do: :ok

  defp handle_non_stream(conn, provider, response, api_key, model, trace_id) do
    usage = extract_usage(response)
    UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
    Helpers.send_json(conn, 200, response)
  end

  defp handle_stream(conn, provider, stream, api_key, model, token, trace_id) do
    conn = SSEWriter.start_sse(conn)
    zero_usage = Usage.zero()

    {conn, usage} =
      try do
        Enum.reduce_while(stream, {conn, zero_usage}, fn %Event{} = event, {conn, usage} ->
          usage = merge_stream_usage(usage, event)

          case SSEWriter.write_event(conn, encode_stream_event(event.data)) do
            {:ok, conn} -> {:cont, {conn, usage}}
            {:error, _reason} -> {:halt, {conn, usage}}
          end
        end)
      rescue
        e in [RuntimeError, Jason.DecodeError, Protocol.UndefinedError] ->
          error_msg = Exception.message(e)
          Logger.error("Stream error: #{error_msg}")

          if String.contains?(error_msg, "429") && token,
            do: RateLimit.mark_rate_limited(token)

          error_event =
            Jason.encode!(%{type: "error", error: %{type: "api_error", message: error_msg}})

          Plug.Conn.chunk(conn, "data: #{error_event}\n\n")
          {conn, zero_usage}
      end

    Plug.Conn.chunk(conn, "data: [DONE]\n\n")
    UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
    conn
  end

  defp encode_stream_event(event) when is_binary(event), do: event
  defp encode_stream_event(event), do: Jason.encode!(event)

  defp merge_stream_usage(_usage, %Event{usage: event_usage}) when not is_nil(event_usage),
    do: event_usage

  defp merge_stream_usage(_usage, %Event{
         data: %{
           "type" => "response.completed",
           "response" => %{"usage" => resp_usage}
         }
       })
       when is_map(resp_usage) do
    Usage.from_responses(resp_usage)
  end

  defp merge_stream_usage(usage, _event), do: usage

  defp extract_usage(response) do
    usage = response["usage"] || %{}
    Usage.from_responses(usage)
  end

  defp tracking_opts(provider, trace_id) do
    %{provider: provider.name(), metadata: %{"trace_id" => trace_id}}
  end

  defp send_error(conn, status, type, message) do
    Helpers.send_json(conn, status, %{error: %{type: type, message: message}})
  end
end
