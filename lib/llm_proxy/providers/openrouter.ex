defmodule LLMProxy.Providers.OpenRouter do
  @behaviour LLMProxy.Providers.Behaviour

  require Logger

  @base_url "https://openrouter.ai/api/v1"

  @impl true
  def name, do: "openrouter"

  @impl true
  def models do
    :llm_proxy
    |> :code.priv_dir()
    |> Path.join("openrouter_models.json")
    |> File.read!()
    |> Jason.decode!()
  end

  @impl true
  def call(body, user_id) do
    with {:ok, token} <- LLMProxy.TokenPool.Server.pick_token("openrouter", user_id) do
      case Req.post(
             url: "#{base_url(token)}/chat/completions",
             headers: headers(token),
             json: body,
             receive_timeout: 600_000
           ) do
        {:ok, %{status: 200, body: response}} ->
          {:ok, %{response: response, token: token}}

        {:ok, %{status: status, body: body}} ->
          error = extract_error(body)
          maybe_mark_rate_limited(token, status)
          {:error, %{error: error, status: status, token: token}}

        {:error, exception} ->
          {:error, %{error: Exception.message(exception), status: 502, token: nil}}
      end
    else
      {:error, reason} ->
        {:error, %{error: "No available tokens: #{reason}", status: 503, token: nil}}
    end
  end

  @impl true
  def stream(body, user_id) do
    with {:ok, token} <- LLMProxy.TokenPool.Server.pick_token("openrouter", user_id) do
      stream_body = Map.put(body, "stream", true)

      case Req.post(
             url: "#{base_url(token)}/chat/completions",
             headers: headers(token),
             json: stream_body,
             into: :self,
             receive_timeout: 600_000
           ) do
        {:ok, %{status: 200} = resp} ->
          stream =
            resp.body
            |> parse_sse_events()
            |> Stream.map(&to_stream_event/1)
            |> Stream.reject(&is_nil/1)

          {:ok, %{stream: stream, token: token}}

        {:ok, %{status: status, body: body}} ->
          error = extract_error(body)
          maybe_mark_rate_limited(token, status)
          {:error, %{error: error, status: status, token: token}}

        {:error, exception} ->
          {:error, %{error: Exception.message(exception), status: 502, token: nil}}
      end
    else
      {:error, reason} ->
        {:error, %{error: "No available tokens: #{reason}", status: 503, token: nil}}
    end
  end

  @impl true
  def extract_usage(response) do
    usage = response["usage"] || %{}

    cache_read =
      get_in(response, ["usage", "prompt_tokens_details", "cached_tokens"]) || 0

    %{
      input_tokens: usage["prompt_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || 0,
      cache_read_tokens: cache_read,
      cache_write_tokens: 0
    }
  end

  @impl true
  def to_openai_response(response, model) do
    Map.put(response, "model", model)
  end

  # Private

  defp headers(token) do
    [
      {"authorization", "Bearer #{token.token}"},
      {"http-referer", "https://ai-proxy.dannote.net"},
      {"x-title", "LLM Proxy"},
      {"content-type", "application/json"}
    ]
  end

  defp base_url(%{proxy: proxy}) when is_binary(proxy) and proxy != "", do: proxy
  defp base_url(_token), do: @base_url

  defp parse_sse_events(async_body) do
    async_body
    |> Stream.transform("", fn chunk, buffer ->
      {events, remaining} = ServerSentEvents.parse(buffer <> chunk)
      {events, remaining}
    end)
  end

  defp to_stream_event(%{data: "[DONE]"}), do: nil

  defp to_stream_event(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} -> to_stream_event_from_map(parsed)
      {:error, _} -> nil
    end
  end

  defp to_stream_event(%{data: data}) when is_map(data) do
    to_stream_event_from_map(data)
  end

  defp to_stream_event(_), do: nil

  defp to_stream_event_from_map(parsed) do
    event = %{data: parsed}

    case parsed do
      %{"usage" => usage} when is_map(usage) ->
        cache_read =
          get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

        Map.put(event, :usage, %{
          input_tokens: usage["prompt_tokens"] || 0,
          output_tokens: usage["completion_tokens"] || 0,
          cache_read_tokens: cache_read,
          cache_write_tokens: 0
        })

      _ ->
        event
    end
  end

  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error(body) when is_binary(body), do: body
  defp extract_error(body), do: inspect(body)

  defp maybe_mark_rate_limited(token, 429),
    do: LLMProxy.TokenPool.Server.mark_rate_limited(token)

  defp maybe_mark_rate_limited(_token, _status), do: :ok
end
