defmodule LLMProxy.Providers.Anthropic do
  @moduledoc false

  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.HTTP
  alias LLMProxy.Protocol
  alias LLMProxy.Providers.{ProviderError, ResponseHandler, Result, SSE, TokenAccess}
  alias LLMProxy.Stream.Event

  @impl true
  def name, do: "anthropic"

  @impl true
  def native_protocol, do: :anthropic

  @impl true
  def models, do: LLMProxy.ModelDB.provider_model_ids(:anthropic)

  @impl true
  def call(body, user_id) do
    with {:ok, token} <- TokenAccess.pick_token("anthropic", user_id) do
      do_call(body, token)
    end
  end

  @impl true
  def stream(body, user_id) do
    with {:ok, token} <- TokenAccess.pick_token("anthropic", user_id) do
      body |> Map.put("stream", true) |> do_stream(token)
    end
  end

  @impl true
  def call_native(body, user_id) do
    with {:ok, token} <- TokenAccess.pick_token("anthropic", user_id) do
      do_call(body, token)
    end
  end

  @impl true
  def stream_native(body, user_id) do
    with {:ok, token} <- TokenAccess.pick_token("anthropic", user_id) do
      body |> Map.put("stream", true) |> do_stream(token)
    end
  end

  @impl true
  def extract_usage(response), do: Protocol.Anthropic.extract_usage(response)

  @impl true
  def to_openai_response(response, model) do
    Protocol.OpenAI.convert_response(response, :anthropic, model)
  end

  # HTTP calls

  defp do_call(body, token) do
    req =
      HTTP.new(
        url: "#{base_url(token)}/messages",
        headers: headers(token),
        receive_timeout: LLMProxy.Config.provider_receive_timeout_ms()
      )

    ResponseHandler.post(req, body, token)
  end

  defp do_stream(body, token) do
    req =
      HTTP.new(
        url: "#{base_url(token)}/messages",
        headers: headers(token),
        into: :self,
        receive_timeout: LLMProxy.Config.provider_receive_timeout_ms()
      )

    case Req.post(req, json: body) do
      {:ok, %{status: 200} = resp} ->
        stream =
          resp.body
          |> SSE.parse_events()
          |> Stream.map(&to_stream_event/1)
          |> Stream.reject(&is_nil/1)

        {:ok, Result.stream(stream, token)}

      {:ok, response} ->
        ProviderError.handle_response(token, response)

      {:error, exception} ->
        ProviderError.handle_exception(exception)
    end
  end

  # Headers & URL

  defp headers(token) do
    [
      {"x-api-key", token.token},
      {"anthropic-version", LLMProxy.Config.provider_value("anthropic", :api_version)},
      {"anthropic-beta", LLMProxy.Config.provider_value("anthropic", :beta)},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  defp base_url(%{proxy: proxy}) when is_binary(proxy) and proxy != "", do: proxy
  defp base_url(_token), do: LLMProxy.Config.provider_value("anthropic", :base_url)

  # Streaming

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

  defp to_stream_event_from_map(%{"type" => "message_start", "message" => msg}) do
    event = Event.new(%{"type" => "message_start", "message" => msg})
    maybe_attach_usage(event, msg["usage"])
  end

  defp to_stream_event_from_map(%{"type" => "message_delta"} = parsed) do
    event = Event.new(parsed)
    maybe_attach_usage(event, parsed["usage"])
  end

  defp to_stream_event_from_map(parsed) do
    Event.new(parsed)
  end

  defp maybe_attach_usage(event, nil), do: event

  defp maybe_attach_usage(event, usage) do
    Event.attach_usage(event, Protocol.Anthropic.extract_usage(%{"usage" => usage}))
  end
end
