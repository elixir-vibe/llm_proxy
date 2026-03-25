defmodule LLMProxy.Providers.Anthropic do
  @moduledoc false

  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.Protocol
  alias LLMProxy.Providers.Helpers

  @default_base_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"
  @beta "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14"

  @models_path Path.join(:code.priv_dir(:llm_proxy), "models/anthropic.json")
  @external_resource @models_path
  @models @models_path |> File.read!() |> Jason.decode!()

  @impl true
  def name, do: "anthropic"

  @impl true
  def native_protocol, do: :anthropic

  @impl true
  def models, do: @models

  @impl true
  def call(body, user_id) do
    with {:ok, token} <- Helpers.pick_token("anthropic", user_id) do
      body |> Protocol.Anthropic.from_openai() |> do_call(token)
    end
  end

  @impl true
  def stream(body, user_id) do
    with {:ok, token} <- Helpers.pick_token("anthropic", user_id) do
      body |> Protocol.Anthropic.from_openai() |> Map.put("stream", true) |> do_stream(token)
    end
  end

  @impl true
  def call_native(body, user_id) do
    with {:ok, token} <- Helpers.pick_token("anthropic", user_id) do
      do_call(body, token)
    end
  end

  @impl true
  def stream_native(body, user_id) do
    with {:ok, token} <- Helpers.pick_token("anthropic", user_id) do
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
    req = Req.new(url: "#{base_url(token)}/messages", headers: headers(token), receive_timeout: 600_000) |> OpentelemetryReq.attach()

    case Req.post(req, json: body) do
      {:ok, %{status: 200, body: response}} -> {:ok, %{response: response, token: token}}
      {:ok, %{status: status, body: resp_body}} -> Helpers.handle_error_response(token, status, resp_body)
      {:error, exception} -> Helpers.handle_exception(exception)
    end
  end

  defp do_stream(body, token) do
    req =
      Req.new(url: "#{base_url(token)}/messages", headers: headers(token), into: :self, receive_timeout: 600_000)
      |> OpentelemetryReq.attach()

    case Req.post(req, json: body) do
      {:ok, %{status: 200} = resp} ->
        stream =
          resp.body
          |> Helpers.parse_sse_events()
          |> Stream.map(&to_stream_event/1)
          |> Stream.reject(&is_nil/1)

        {:ok, %{stream: stream, token: token}}

      {:ok, %{status: status, body: resp_body}} ->
        Helpers.handle_error_response(token, status, resp_body)

      {:error, exception} ->
        Helpers.handle_exception(exception)
    end
  end

  # Headers & URL

  defp headers(token) do
    [
      {"x-api-key", token.token},
      {"anthropic-version", @api_version},
      {"anthropic-beta", @beta},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  defp base_url(%{proxy: proxy}) when is_binary(proxy) and proxy != "", do: proxy
  defp base_url(_token), do: @default_base_url

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
    event = %{data: %{"type" => "message_start", "message" => msg}}
    maybe_attach_usage(event, msg["usage"])
  end

  defp to_stream_event_from_map(%{"type" => "message_delta"} = parsed) do
    event = %{data: parsed}
    maybe_attach_usage(event, parsed["usage"])
  end

  defp to_stream_event_from_map(parsed) do
    %{data: parsed}
  end

  defp maybe_attach_usage(event, nil), do: event

  defp maybe_attach_usage(event, usage) do
    Map.put(event, :usage, %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_read_tokens: usage["cache_read_input_tokens"] || 0,
      cache_write_tokens: usage["cache_creation_input_tokens"] || 0
    })
  end
end
