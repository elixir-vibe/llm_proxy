defmodule LLMProxy.Routes.Responses do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Routes.Helpers
  alias LLMProxy.Stream.{Event, SSEWriter}
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
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]

    with {:ok, request} <- Request.parse(:openai_responses, body),
         :ok <- Helpers.check_model_access(api_key, model),
         provider when not is_nil(provider) <- Registry.get_provider(model) do
      Logger.debug(
        "Responses request from #{api_key.name} model=#{model} stream=#{responses_stream?(request)}"
      )

      Helpers.log_user_message(api_key, model, "responses", fn -> Request.user_text(request) end)
      dispatch_provider(conn, provider, normalize_stream(request), api_key, model)
    else
      nil ->
        send_error(conn, 404, "not_found_error", "Model '#{model}' not found")

      {:error, %Request.Error{} = error} ->
        send_error(conn, 400, error.code, error.message)

      {:error, reason} ->
        send_error(conn, 403, "permission_error", reason)
    end
  end

  defp normalize_stream(%Request{stream: false} = request), do: request

  defp normalize_stream(%Request{} = request),
    do: %{request | body: Map.put(request.body, "stream", true), stream: true}

  defp responses_stream?(%Request{} = request), do: normalize_stream(request).stream

  defp dispatch_provider(conn, provider, %Request{} = request, api_key, model) do
    cond do
      request.stream == true and function_exported?(provider, :stream_native, 2) ->
        stream_native_provider(conn, provider, request, api_key, model)

      request.stream == true ->
        unsupported_api(conn, model)

      function_exported?(provider, :call_native, 2) ->
        call_native_provider(conn, provider, request, api_key, model)

      true ->
        unsupported_api(conn, model)
    end
  end

  defp unsupported_api(conn, model) do
    send_error(
      conn,
      400,
      "invalid_request_error",
      "Model '#{model}' does not support Responses API"
    )
  end

  defp stream_native_provider(conn, provider, %Request{} = request, api_key, model) do
    case provider.stream_native(Request.native_body(request), api_key.id) do
      {:ok, %Result{stream: stream_enum, token: token}} ->
        handle_stream(conn, stream_enum, api_key, model, token)

      {:error, result} ->
        handle_provider_error(conn, provider, result)
    end
  end

  defp call_native_provider(conn, provider, %Request{} = request, api_key, model) do
    case provider.call_native(Request.native_body(request), api_key.id) do
      {:ok, %Result{response: response}} when not is_nil(response) ->
        handle_non_stream(conn, response, api_key, model)

      {:ok, %Result{stream: stream_enum, token: token}} when not is_nil(stream_enum) ->
        handle_stream(conn, stream_enum, api_key, model, token)

      {:error, result} ->
        handle_provider_error(conn, provider, result)
    end
  end

  defp handle_provider_error(conn, provider, %Result{error: error, status: status} = result) do
    token = Map.get(result, :token)
    if status == 429 && token, do: Helpers.mark_rate_limited(token)
    Logger.error("#{provider.name()} error (#{status}): #{error}")
    send_error(conn, status, "api_error", error)
  end

  defp handle_non_stream(conn, response, api_key, model) do
    usage = extract_usage(response)
    Helpers.track_usage(api_key, model, usage)
    Helpers.send_json(conn, 200, response)
  end

  defp handle_stream(conn, stream, api_key, model, token) do
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
          if String.contains?(error_msg, "429") && token, do: Helpers.mark_rate_limited(token)

          error_event =
            Jason.encode!(%{type: "error", error: %{type: "api_error", message: error_msg}})

          Plug.Conn.chunk(conn, "data: #{error_event}\n\n")
          {conn, zero_usage}
      end

    Plug.Conn.chunk(conn, "data: [DONE]\n\n")
    Helpers.track_usage(api_key, model, usage)
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

  defp send_error(conn, status, type, message) do
    Helpers.send_json(conn, status, %{error: %{type: type, message: message}})
  end
end
