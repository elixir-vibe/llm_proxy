defmodule LLMProxy.Providers.Caller do
  @moduledoc """
  Wraps provider calls with retry and fallback logic.

  On retryable errors (5xx, timeout, connection errors), tries fallback
  providers configured via `config :llm_proxy, :fallbacks`.
  Rate-limited (429) tokens are marked and the next token/provider is tried.
  """

  require Logger

  alias LLMProxy.Config
  alias LLMProxy.Providers.Registry

  @retryable_statuses [500, 502, 503, 504, 529]

  def call(provider, body, user_id, model) do
    attempts = build_attempts(provider, model)
    try_call(attempts, body, user_id, nil)
  end

  def stream(provider, body, user_id, model) do
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
    call_body = Map.put(body, "model", model)

    case provider.call(call_body, user_id) do
      {:ok, _} = success ->
        if rest != [] do
          Logger.info("Fallback to #{provider.name()}/#{model} succeeded")
        end

        success

      {:error, %{status: status}} = error when status in @retryable_statuses ->
        Logger.warning("#{provider.name()}/#{model} returned #{status}, trying fallback")
        try_call(rest, body, user_id, error)

      {:error, %{status: 429}} = error ->
        Logger.warning("#{provider.name()}/#{model} rate-limited, trying fallback")
        try_call(rest, body, user_id, error)

      {:error, _} = error ->
        error
    end
  end

  defp try_stream([], _body, _user_id, last_error), do: last_error

  defp try_stream([{provider, model} | rest], body, user_id, _last_error) do
    stream_body = Map.put(body, "model", model)

    case provider.stream(stream_body, user_id) do
      {:ok, _} = success ->
        if rest != [] do
          Logger.info("Fallback to #{provider.name()}/#{model} succeeded (stream)")
        end

        success

      {:error, %{status: status}} = error when status in @retryable_statuses ->
        Logger.warning("#{provider.name()}/#{model} returned #{status}, trying fallback (stream)")
        try_stream(rest, body, user_id, error)

      {:error, %{status: 429}} = error ->
        Logger.warning("#{provider.name()}/#{model} rate-limited, trying fallback (stream)")
        try_stream(rest, body, user_id, error)

      {:error, _} = error ->
        error
    end
  end
end
