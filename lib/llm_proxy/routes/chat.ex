defmodule LLMProxy.Routes.Chat do
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

  post "/completions" do
    handle_chat(conn)
  end

  match _ do
    Helpers.send_json(conn, 404, %{error: "Not found"})
  end

  defp handle_chat(conn) do
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]

    with :ok <- Helpers.check_model_access(api_key, model),
         provider when not is_nil(provider) <- Registry.get_provider(model) do
      Logger.debug("Request from #{api_key.name} model=#{model} provider=#{provider.name()}")
      Helpers.log_user_message(api_key, model, "chat", fn -> extract_user_message(body) end)

      if body["stream"] do
        handle_stream(conn, provider, api_key, body, model)
      else
        handle_non_stream(conn, provider, api_key, body, model)
      end
    else
      nil -> Helpers.send_json(conn, 404, %{error: "Model '#{model}' not found"})
      {:error, reason} -> Helpers.send_json(conn, 403, %{error: reason})
    end
  end

  defp handle_non_stream(conn, provider, api_key, body, model) do
    case provider.call(body, api_key.id) do
      {:ok, %{response: response}} ->
        Helpers.track_usage(api_key, model, provider.extract_usage(response))
        Helpers.send_json(conn, 200, provider.to_openai_response(response, model))

      {:error, %{error: error, status: status}} ->
        Logger.error("#{provider.name()} error (#{status}): #{error}")
        Helpers.send_json(conn, status, %{error: error})
    end
  end

  defp handle_stream(conn, provider, api_key, body, model) do
    case provider.stream(body, api_key.id) do
      {:ok, %{stream: stream}} ->
        conn = SSEWriter.start_sse(conn)
        {conn, usage} = pipe_stream(conn, stream)
        Helpers.track_usage(api_key, model, usage)
        conn

      {:error, %{error: error, status: status}} ->
        Logger.error("#{provider.name()} stream error (#{status}): #{error}")
        Helpers.send_json(conn, status, %{error: error})
    end
  end

  defp pipe_stream(conn, stream) do
    usage = %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0}

    Enum.reduce_while(stream, {conn, usage}, fn event, {conn, usage} ->
      usage = merge_stream_usage(usage, event)

      case SSEWriter.write_event(conn, event.data) do
        {:ok, conn} -> {:cont, {conn, usage}}
        {:error, _reason} -> {:halt, {conn, usage}}
      end
    end)
    |> then(fn {conn, usage} ->
      {:ok, conn} = SSEWriter.write_done(conn)
      {conn, usage}
    end)
  end

  defp merge_stream_usage(usage, %{usage: event_usage}) when is_map(event_usage) do
    Map.merge(usage, event_usage, fn _k, v1, v2 -> max(v1, v2) end)
  end

  defp merge_stream_usage(usage, _), do: usage

  defp extract_user_message(%{"messages" => messages}) when is_list(messages) do
    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      %{"role" => "user", "content" => parts} when is_list(parts) -> Helpers.extract_text_parts(parts)
      _ -> ""
    end
  end

  defp extract_user_message(_), do: ""
end
