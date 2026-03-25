defmodule LLMProxy.Providers.Helpers do
  @moduledoc false

  alias LLMProxy.TokenPool.Server, as: TokenPool

  def pick_token(provider_name, user_id) do
    case TokenPool.pick_token(provider_name, user_id) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, %{error: "No available tokens: #{reason}", status: 503, token: nil}}
    end
  end

  def openai_call(provider_name, body, user_id, opts) do
    with {:ok, token} <- pick_token(provider_name, user_id) do
      base_url = opts.base_url_fn.(token)
      headers = opts.headers_fn.(token)

      req = Req.new(url: "#{base_url}/chat/completions", headers: headers, receive_timeout: 600_000) |> OpentelemetryReq.attach()

      case Req.post(req, json: body) do
        {:ok, %{status: 200, body: response}} -> {:ok, %{response: response, token: token}}
        {:ok, %{status: status, body: resp_body}} -> handle_error_response(token, status, resp_body)
        {:error, exception} -> handle_exception(exception)
      end
    end
  end

  def openai_stream(provider_name, body, user_id, opts) do
    with {:ok, token} <- pick_token(provider_name, user_id) do
      base_url = opts.base_url_fn.(token)
      headers = opts.headers_fn.(token)
      stream_body = Map.put(body, "stream", true)

      req =
        Req.new(url: "#{base_url}/chat/completions", headers: headers, into: :self, receive_timeout: 600_000)
        |> OpentelemetryReq.attach()

      case Req.post(req, json: stream_body) do
        {:ok, %{status: 200} = resp} ->
          stream =
            resp.body
            |> parse_sse_events()
            |> Stream.map(&openai_to_stream_event/1)
            |> Stream.reject(&is_nil/1)

          {:ok, %{stream: stream, token: token}}

        {:ok, %{status: status, body: resp_body}} ->
          handle_error_response(token, status, resp_body)

        {:error, exception} ->
          handle_exception(exception)
      end
    end
  end

  def extract_openai_usage(response) do
    LLMProxy.Protocol.OpenAI.extract_usage(response)
  end

  def openai_stream_event_from_map(parsed) do
    event = %{data: parsed}

    case parsed do
      %{"usage" => usage} when is_map(usage) ->
        cache_read = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

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

  def parse_sse_events(async_body) do
    async_body
    |> Stream.transform("", fn chunk, buffer ->
      {events, remaining} = ServerSentEvents.parse(buffer <> chunk)
      {events, remaining}
    end)
  end

  def handle_error_response(token, status, body) do
    if status == 429, do: TokenPool.mark_rate_limited(token)
    {:error, %{error: extract_error(body), status: status, token: token}}
  end

  def handle_exception(exception) do
    {:error, %{error: Exception.message(exception), status: 502, token: nil}}
  end

  def extract_error(%{"error" => %{"message" => msg}}), do: msg
  def extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  def extract_error(body) when is_binary(body), do: body
  def extract_error(body), do: inspect(body)

  defp openai_to_stream_event(%{data: "[DONE]"}), do: nil

  defp openai_to_stream_event(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} -> openai_stream_event_from_map(parsed)
      {:error, _} -> nil
    end
  end

  defp openai_to_stream_event(%{data: data}) when is_map(data) do
    openai_stream_event_from_map(data)
  end

  defp openai_to_stream_event(_), do: nil
end
