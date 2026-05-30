defmodule LLMProxy.Providers.Caller do
  @moduledoc """
  Wraps provider calls with retry and fallback logic.

  On retryable errors (5xx, timeout, connection errors), tries fallback
  providers configured via `config :llm_proxy, :fallbacks`.
  Rate-limited (429) tokens are marked and the next token/provider is tried.
  """

  require Logger

  alias LLMProxy.Config
  alias LLMProxy.Protocol
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Registry, Result}

  @retryable_statuses [500, 502, 503, 504, 529]

  def call(provider, %Request{} = body, user_id, model) do
    attempts = build_attempts(provider, model)
    try_call(attempts, body, user_id, nil)
  end

  def stream(provider, %Request{} = body, user_id, model) do
    attempts = build_attempts(provider, model)
    try_stream(attempts, body, user_id, nil)
  end

  defp build_attempts(provider, model) do
    primary = {provider, model}
    fallbacks = Registry.get_fallbacks(model)
    max = Config.max_retries()

    [primary | Enum.take(fallbacks, max)]
  end

  defp try_call([], _body, _user_id, last_error), do: last_error

  defp try_call([{provider, model} | rest], body, user_id, _last_error) do
    call_body = prepare_body(body, provider, model)

    case provider.call(call_body, user_id) do
      {:ok, result} ->
        if rest != [] do
          Logger.info("Fallback to #{provider.name()}/#{model} succeeded")
        end

        Result.with_attempt({:ok, result}, provider, model)

      {:error, %Result{status: status}} = error when status in @retryable_statuses ->
        Logger.warning("#{provider.name()}/#{model} returned #{status}, trying fallback")
        try_call(rest, body, user_id, error)

      {:error, %Result{status: 429}} = error ->
        Logger.warning("#{provider.name()}/#{model} rate-limited, trying fallback")
        try_call(rest, body, user_id, error)

      {:error, _} = error ->
        error
    end
  end

  defp prepare_body(%Request{} = request, provider, model) do
    request = %{request | model: model, body: Map.put(request.body, "model", model)}

    case provider_protocol(provider) do
      :anthropic ->
        Protocol.Anthropic.request_body(request)

      :openai ->
        Protocol.OpenAI.request_body(request)
    end
  end

  defp provider_protocol(provider) do
    if function_exported?(provider, :native_protocol, 0),
      do: provider.native_protocol(),
      else: :openai
  end

  defp try_stream([], _body, _user_id, last_error), do: last_error

  defp try_stream([{provider, model} | rest], body, user_id, _last_error) do
    stream_body = prepare_body(body, provider, model)

    case provider.stream(stream_body, user_id) do
      {:ok, result} ->
        if rest != [] do
          Logger.info("Fallback to #{provider.name()}/#{model} succeeded (stream)")
        end

        Result.with_attempt({:ok, result}, provider, model)

      {:error, %Result{status: status}} = error when status in @retryable_statuses ->
        Logger.warning("#{provider.name()}/#{model} returned #{status}, trying fallback (stream)")
        try_stream(rest, body, user_id, error)

      {:error, %Result{status: 429}} = error ->
        Logger.warning("#{provider.name()}/#{model} rate-limited, trying fallback (stream)")
        try_stream(rest, body, user_id, error)

      {:error, _} = error ->
        error
    end
  end
end
