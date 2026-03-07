defmodule LLMProxy.Routes.Responses do
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
    handle_responses(conn)
  end

  match _ do
    send_error(conn, 404, "not_found_error", "Not found")
  end

  defp handle_responses(conn) do
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]
    stream = body["stream"] != false

    with :ok <- Helpers.check_model_access(api_key, model),
         provider when not is_nil(provider) <- Registry.get_provider(model) do
      Logger.debug("Responses request from #{api_key.name} model=#{model} stream=#{stream}")
      Helpers.log_user_message(api_key, model, "responses", fn -> extract_user_message(body) end)
      dispatch_provider(conn, provider, Map.put(body, "stream", stream), api_key, model)
    else
      nil -> send_error(conn, 404, "not_found_error", "Model '#{model}' not found")
      {:error, reason} -> send_error(conn, 403, "permission_error", reason)
    end
  end

  defp dispatch_provider(conn, provider, body, api_key, model) do
    case provider.call_native(body, api_key.id) do
      {:ok, %{stream: stream_enum, token: token}} ->
        handle_stream(conn, stream_enum, api_key, model, token)

      {:ok, %{response: response}} ->
        handle_non_stream(conn, response, api_key, model)

      {:error, %{error: error, status: status} = result} ->
        token = Map.get(result, :token)
        if status == 429 && token, do: Helpers.mark_rate_limited(token)
        Logger.error("#{provider.name()} error (#{status}): #{error}")
        send_error(conn, status, "api_error", error)
    end
  end

  defp handle_non_stream(conn, response, api_key, model) do
    usage = extract_usage(response)
    Helpers.track_usage(api_key, model, usage)
    Helpers.send_json(conn, 200, response)
  end

  defp handle_stream(conn, stream, api_key, model, token) do
    conn = SSEWriter.start_sse(conn)
    zero_usage = %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0}

    {conn, usage} =
      try do
        Enum.reduce_while(stream, {conn, zero_usage}, fn event, {conn, usage} ->
          usage = merge_stream_usage(usage, event)

          case SSEWriter.write_event(conn, encode_stream_event(event)) do
            {:ok, conn} -> {:cont, {conn, usage}}
            {:error, _reason} -> {:halt, {conn, usage}}
          end
        end)
      rescue
        e ->
          error_msg = Exception.message(e)
          Logger.error("Stream error: #{error_msg}")
          if String.contains?(error_msg, "429") && token, do: Helpers.mark_rate_limited(token)

          error_event = Jason.encode!(%{type: "error", error: %{type: "api_error", message: error_msg}})
          Plug.Conn.chunk(conn, "data: #{error_event}\n\n")
          {conn, zero_usage}
      end

    Plug.Conn.chunk(conn, "data: [DONE]\n\n")
    Helpers.track_usage(api_key, model, usage)
    conn
  end

  defp encode_stream_event(event) when is_binary(event), do: event
  defp encode_stream_event(event), do: Jason.encode!(event)

  defp merge_stream_usage(_usage, %{"type" => "response.completed", "response" => %{"usage" => resp_usage}})
       when is_map(resp_usage) do
    cached = get_in(resp_usage, ["input_tokens_details", "cached_tokens"]) || 0
    input = (resp_usage["input_tokens"] || 0) - cached

    %{
      input_tokens: input,
      output_tokens: resp_usage["output_tokens"] || 0,
      cache_read_tokens: cached
    }
  end

  defp merge_stream_usage(usage, _event), do: usage

  defp extract_usage(response) do
    usage = response["usage"] || %{}
    cached = get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0
    input = (usage["input_tokens"] || 0) - cached

    %{
      input_tokens: input,
      output_tokens: usage["output_tokens"] || 0,
      cache_read_tokens: cached
    }
  end

  defp extract_user_message(%{"input" => input}) when is_list(input) do
    case List.last(input) do
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      %{"role" => "user", "content" => parts} when is_list(parts) -> extract_text_parts(parts)
      _ -> ""
    end
  end

  defp extract_user_message(_), do: ""

  defp extract_text_parts(parts) do
    parts
    |> Enum.map(fn
      %{"type" => "input_text", "text" => text} -> text
      %{"type" => "text", "text" => text} -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp send_error(conn, status, type, message) do
    Helpers.send_json(conn, status, %{error: %{type: type, message: message}})
  end
end
