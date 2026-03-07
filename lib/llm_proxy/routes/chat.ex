defmodule LLMProxy.Routes.Chat do
  use Plug.Router

  require Logger

  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Providers.Registry
  alias LLMProxy.Storage
  alias LLMProxy.Stream.SSEWriter

  plug Auth
  plug QuotaCheck
  plug :match
  plug :dispatch

  post "/completions" do
    handle_chat(conn)
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp handle_chat(conn) do
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]

    with :ok <- check_model_access(api_key, model),
         provider when not is_nil(provider) <- Registry.get_provider(model) do
      Logger.debug("Request from #{api_key.name} model=#{model} provider=#{provider.name()}")
      log_user_message(api_key, model, body)

      if body["stream"] do
        handle_stream(conn, provider, api_key, body, model)
      else
        handle_non_stream(conn, provider, api_key, body, model)
      end
    else
      nil ->
        send_json(conn, 404, %{error: "Model '#{model}' not found"})

      {:error, reason} ->
        send_json(conn, 403, %{error: reason})
    end
  end

  defp handle_non_stream(conn, provider, api_key, body, model) do
    case provider.call(body, api_key.id) do
      {:ok, %{response: response}} ->
        track_usage(api_key, model, provider.extract_usage(response))
        openai_response = provider.to_openai_response(response, model)
        send_json(conn, 200, openai_response)

      {:error, %{error: error, status: status}} ->
        Logger.error("#{provider.name()} error (#{status}): #{error}")
        send_json(conn, status, %{error: error})
    end
  end

  defp handle_stream(conn, provider, api_key, body, model) do
    case provider.stream(body, api_key.id) do
      {:ok, %{stream: stream}} ->
        conn = SSEWriter.start_sse(conn)
        {conn, usage} = pipe_stream(conn, stream, model, provider)
        track_usage(api_key, model, usage)
        conn

      {:error, %{error: error, status: status}} ->
        Logger.error("#{provider.name()} stream error (#{status}): #{error}")
        send_json(conn, status, %{error: error})
    end
  end

  defp pipe_stream(conn, stream, _model, _provider) do
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

  defp track_usage(%{id: "master"}, _model, _usage), do: :ok

  defp track_usage(api_key, model, usage) do
    Storage.update_key_usage(api_key, %{
      input: usage.input_tokens,
      output: usage.output_tokens,
      cache_read: usage.cache_read_tokens,
      cache_write: usage.cache_write_tokens
    })

    Storage.record_usage(%{
      key_id: api_key.id,
      model: model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens,
      timestamp: DateTime.utc_now()
    })

    Logger.info("Completed #{api_key.name} model=#{model} in=#{usage.input_tokens} out=#{usage.output_tokens}")
  end

  defp check_model_access(%{id: "master"}, _model), do: :ok
  defp check_model_access(api_key, model), do: Storage.check_model_access(api_key, model)

  defp log_user_message(api_key, model, body) do
    case extract_user_message(body) do
      "" -> :ok
      msg ->
        Storage.log_message(%{key_id: api_key.id, model: model, route: "chat", user_message: msg})
    end
  end

  defp extract_user_message(%{"messages" => messages}) when is_list(messages) do
    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      %{"role" => "user", "content" => parts} when is_list(parts) ->
        parts
        |> Enum.map(fn
          %{"type" => "text", "text" => text} -> text
          text when is_binary(text) -> text
          _ -> ""
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      _ -> ""
    end
  end

  defp extract_user_message(_), do: ""

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
