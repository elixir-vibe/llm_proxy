defmodule LLMProxy.HTTP.Routes.Messages do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.AccessControl
  alias LLMProxy.HTTP.Routes.Helpers
  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Stream.{Event, SSEWriter}
  alias LLMProxy.Telemetry
  alias LLMProxy.TokenRateLimit
  alias LLMProxy.Trace
  alias LLMProxy.Usage
  alias LLMProxy.UsageTracking

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

    with {:ok, request} <- Request.parse(:anthropic_messages, body),
         :ok <- AccessControl.check_model_access(api_key, model),
         provider when not is_nil(provider) <- Registry.get_provider(model) do
      Logger.debug(
        "Messages request from #{api_key.name} model=#{model} stream=#{request.stream || false}"
      )

      UsageTracking.log_user_message(api_key, model, "messages", fn ->
        Request.user_text(request)
      end)

      dispatch_provider(conn, provider, request, api_key, model, trace_id)
    else
      nil ->
        send_error(conn, 404, "not_found_error", "Model '#{model}' not found")

      {:error, %Request.Error{} = error} ->
        send_error(conn, 400, error.code, error.message)

      {:error, reason} ->
        send_error(conn, 403, "permission_error", reason)
    end
  end

  defp dispatch_provider(
         conn,
         provider,
         %Request{stream: true} = request,
         api_key,
         model,
         trace_id
       ) do
    if function_exported?(provider, :stream_native, 2) do
      stream_native_provider(conn, provider, request, api_key, model, trace_id)
    else
      unsupported_api(conn, model)
    end
  end

  defp dispatch_provider(conn, provider, %Request{} = request, api_key, model, trace_id) do
    if function_exported?(provider, :call_native, 2) do
      call_native_provider(conn, provider, request, api_key, model, trace_id)
    else
      unsupported_api(conn, model)
    end
  end

  defp unsupported_api(conn, model) do
    send_error(
      conn,
      400,
      "invalid_request_error",
      "Model '#{model}' does not support Messages API"
    )
  end

  defp stream_native_provider(conn, provider, %Request{} = request, api_key, model, trace_id) do
    case native_span(provider, model, :messages_stream, trace_id, fn ->
           provider.stream_native(Request.native_body(request), api_key.id)
         end) do
      {:ok, %Result{stream: stream, token: token}} ->
        handle_stream(conn, provider, stream, api_key, model, token, trace_id)

      {:error, result} ->
        handle_provider_error(conn, provider, result)
    end
  end

  defp call_native_provider(conn, provider, %Request{} = request, api_key, model, trace_id) do
    case native_span(provider, model, :messages_call, trace_id, fn ->
           provider.call_native(Request.native_body(request), api_key.id)
         end) do
      {:ok, %Result{response: response}} when not is_nil(response) ->
        handle_non_stream(conn, provider, response, api_key, model, trace_id)

      {:ok, %Result{stream: stream, token: token}} when not is_nil(stream) ->
        handle_stream(conn, provider, stream, api_key, model, token, trace_id)

      {:error, result} ->
        handle_provider_error(conn, provider, result)
    end
  end

  defp handle_provider_error(conn, provider, %Result{error: error, status: status} = result) do
    mark_rate_limited_if_needed(status, result)
    Logger.error("#{provider.name()} error (#{status}): #{error}")
    send_error(conn, status, error_type(status), error)
  end

  defp handle_non_stream(conn, provider, response, api_key, model, trace_id) do
    usage = provider.extract_usage(response)
    UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
    Helpers.send_json(conn, 200, response)
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

    if is_rate_limit && token, do: TokenRateLimit.mark_rate_limited(token)
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

  defp native_span(provider, model, operation, trace_id, fun) do
    Telemetry.with_provider_span(provider.name(), model, operation, fun, %{
      "llm_proxy.trace_id" => trace_id
    })
  end

  defp tracking_opts(provider, trace_id) do
    %{provider: provider.name(), metadata: %{"trace_id" => trace_id}}
  end

  defp mark_rate_limited_if_needed(429, %{token: token}) when not is_nil(token) do
    TokenRateLimit.mark_rate_limited(token)
  end

  defp mark_rate_limited_if_needed(_, _), do: :ok

  defp error_type(429), do: "rate_limit_error"
  defp error_type(401), do: "authentication_error"
  defp error_type(400), do: "invalid_request_error"
  defp error_type(_), do: "api_error"

  defp send_error(conn, status, type, message) do
    Helpers.send_json(conn, status, %{type: "error", error: %{type: type, message: message}})
  end
end
