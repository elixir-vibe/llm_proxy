defmodule LLMProxy.Routes.Messages do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Providers.Registry
  alias LLMProxy.Routes.Helpers
  alias LLMProxy.Stream.SSEWriter

  plug Auth
  plug QuotaCheck
  plug :match
  plug :dispatch

  post "/" do
    handle_messages(conn)
  end

  match _ do
    send_error(conn, 404, "not_found_error", "Not found")
  end

  defp handle_messages(conn) do
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]

    with :ok <- Helpers.check_model_access(api_key, model),
         provider when not is_nil(provider) <- Registry.get_provider(model) do
      Logger.debug("Messages request from #{api_key.name} model=#{model} stream=#{body["stream"] || false}")
      Helpers.log_user_message(api_key, model, "messages", fn -> extract_user_message(body) end)
      dispatch_provider(conn, provider, body, api_key, model)
    else
      nil -> send_error(conn, 404, "not_found_error", "Model '#{model}' not found")
      {:error, reason} -> send_error(conn, 403, "permission_error", reason)
    end
  end

  defp dispatch_provider(conn, provider, body, api_key, model) do
    case provider.call_native(body, api_key.id) do
      {:ok, %{stream: stream, token: token}} ->
        handle_stream(conn, provider, stream, api_key, model, token)

      {:ok, %{response: response}} ->
        handle_non_stream(conn, provider, response, api_key, model)

      {:error, %{error: error, status: status} = result} ->
        mark_rate_limited_if_needed(status, result)
        Logger.error("#{provider.name()} error (#{status}): #{error}")
        send_error(conn, status, error_type(status), error)
    end
  end

  defp handle_non_stream(conn, provider, response, api_key, model) do
    usage = provider.extract_usage(response)
    Helpers.track_usage(api_key, model, usage)
    Helpers.send_json(conn, 200, response)
  end

  defp handle_stream(conn, provider, stream, api_key, model, token) do
    conn = SSEWriter.start_sse(conn)
    {conn, usage} = pipe_stream(conn, provider, stream, token)
    Helpers.track_usage(api_key, model, usage)
    conn
  end

  defp pipe_stream(conn, provider, stream, token) do
    zero_usage = %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0}

    try do
      Enum.reduce_while(stream, {conn, zero_usage}, fn event, {conn, usage} ->
        usage = merge_stream_usage(usage, event, provider)

        case SSEWriter.write_named_event(conn, event["type"] || "unknown", event) do
          {:ok, conn} -> {:cont, {conn, usage}}
          {:error, _reason} -> {:halt, {conn, usage}}
        end
      end)
    rescue
      e ->
        handle_stream_error(conn, e, token)
        {conn, zero_usage}
    end
  end

  defp merge_stream_usage(usage, %{"type" => "message_start", "message" => %{"usage" => msg_usage}}, provider) do
    event_usage = provider.extract_usage(%{"usage" => msg_usage})

    %{
      usage
      | input_tokens: event_usage.input_tokens,
        cache_read_tokens: event_usage.cache_read_tokens,
        cache_write_tokens: event_usage.cache_write_tokens
    }
  end

  defp merge_stream_usage(usage, %{"type" => "message_delta", "usage" => delta_usage}, _provider)
       when is_map(delta_usage) do
    %{usage | output_tokens: delta_usage["output_tokens"] || 0}
  end

  defp merge_stream_usage(usage, _event, _provider), do: usage

  defp handle_stream_error(conn, error, token) do
    error_msg = Exception.message(error)
    is_rate_limit = String.contains?(error_msg, "429") || String.contains?(error_msg, "rate_limit")
    if is_rate_limit && token, do: Helpers.mark_rate_limited(token)
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

  defp mark_rate_limited_if_needed(429, %{token: token}) when not is_nil(token) do
    Helpers.mark_rate_limited(token)
  end

  defp mark_rate_limited_if_needed(_, _), do: :ok

  defp extract_user_message(%{"messages" => messages}) when is_list(messages) do
    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      %{"role" => "user", "content" => parts} when is_list(parts) ->
        if Enum.all?(parts, &(&1["type"] == "tool_result")), do: "", else: Helpers.extract_text_parts(parts)
      _ -> ""
    end
  end

  defp extract_user_message(_), do: ""

  defp error_type(429), do: "rate_limit_error"
  defp error_type(401), do: "authentication_error"
  defp error_type(400), do: "invalid_request_error"
  defp error_type(_), do: "api_error"

  defp send_error(conn, status, type, message) do
    Helpers.send_json(conn, status, %{type: "error", error: %{type: type, message: message}})
  end
end
