defmodule LLMProxy.Providers.Caller do
  @moduledoc """
  Wraps provider calls with retry and fallback logic.

  On retryable errors (5xx, timeout, connection errors), tries fallback
  providers configured via `config :llm_proxy, :fallbacks`.
  Rate-limited (429) tokens are marked and the next token/provider is tried.
  """

  require Logger

  alias LLMProxy.CircuitBreaker
  alias LLMProxy.Config
  alias LLMProxy.Protocol
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Routing.Attempt
  alias LLMProxy.Telemetry

  @retryable_statuses [500, 502, 503, 504, 529]

  def call(provider, %Request{} = body, user_id, model) do
    attempts = build_attempts(provider, model)
    call_attempts(attempts, body, user_id)
  end

  def call_attempts(attempts, %Request{} = body, user_id) when is_list(attempts) do
    attempts |> Enum.map(&Attempt.new/1) |> try_call(body, user_id, nil)
  end

  def stream(provider, %Request{} = body, user_id, model) do
    attempts = build_attempts(provider, model)
    stream_attempts(attempts, body, user_id)
  end

  def stream_attempts(attempts, %Request{} = body, user_id) when is_list(attempts) do
    attempts |> Enum.map(&Attempt.new/1) |> try_stream(body, user_id, nil)
  end

  defp build_attempts(provider, model) do
    primary = Attempt.new({provider, model})
    fallbacks = Registry.get_fallbacks(model)
    max = Config.max_retries()

    [primary | Enum.take(fallbacks, max)]
  end

  defp try_call([], _body, _user_id, nil) do
    {:error, Result.error("No healthy deployments available", 503, nil)}
  end

  defp try_call([], _body, _user_id, last_error), do: last_error

  defp try_call([%Attempt{} = attempt | rest], body, user_id, last_error) do
    if CircuitBreaker.available?(attempt) do
      Telemetry.emit([:routing, :attempt, :start], attempt)
      call_body = prepare_body(body, attempt.provider, attempt.model)

      attempt
      |> invoke(:call, [call_body, user_id])
      |> handle_call_result(attempt, rest, body, user_id)
    else
      try_call(rest, body, user_id, last_error)
    end
  end

  defp handle_call_result({:ok, result}, attempt, rest, _body, _user_id) do
    CircuitBreaker.success(attempt)
    Telemetry.emit([:routing, :attempt, :stop], attempt)

    if rest != [] do
      Logger.info("Fallback to #{attempt.provider.name()}/#{attempt.model} succeeded")
    end

    Result.with_attempt({:ok, result}, attempt.provider, attempt.model)
  end

  defp handle_call_result({:error, %Result{status: status}} = error, attempt, rest, body, user_id)
       when status in @retryable_statuses do
    CircuitBreaker.failure(attempt, retry_after(error))
    Telemetry.emit([:routing, :attempt, :exception], attempt, %{status: status})

    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} returned #{status}, trying fallback"
    )

    try_call(rest, body, user_id, error)
  end

  defp handle_call_result({:error, %Result{status: 429}} = error, attempt, rest, body, user_id) do
    CircuitBreaker.failure(attempt, retry_after(error))
    Telemetry.emit([:routing, :attempt, :exception], attempt, %{status: 429})
    Logger.warning("#{attempt.provider.name()}/#{attempt.model} rate-limited, trying fallback")
    try_call(rest, body, user_id, error)
  end

  defp handle_call_result({:error, _result} = error, _attempt, _rest, _body, _user_id), do: error

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

  defp try_stream([], _body, _user_id, nil) do
    {:error, Result.error("No healthy deployments available", 503, nil)}
  end

  defp try_stream([], _body, _user_id, last_error), do: last_error

  defp try_stream([%Attempt{} = attempt | rest], body, user_id, last_error) do
    if CircuitBreaker.available?(attempt) do
      Telemetry.emit([:routing, :stream_attempt, :start], attempt)
      stream_body = prepare_body(body, attempt.provider, attempt.model)

      attempt
      |> invoke(:stream, [stream_body, user_id])
      |> handle_stream_result(attempt, rest, body, user_id)
    else
      try_stream(rest, body, user_id, last_error)
    end
  end

  defp handle_stream_result({:ok, result}, attempt, rest, _body, _user_id) do
    CircuitBreaker.success(attempt)
    Telemetry.emit([:routing, :stream_attempt, :stop], attempt)

    if rest != [] do
      Logger.info("Fallback to #{attempt.provider.name()}/#{attempt.model} succeeded (stream)")
    end

    Result.with_attempt({:ok, result}, attempt.provider, attempt.model)
  end

  defp handle_stream_result(
         {:error, %Result{status: status}} = error,
         attempt,
         rest,
         body,
         user_id
       )
       when status in @retryable_statuses do
    CircuitBreaker.failure(attempt, retry_after(error))
    Telemetry.emit([:routing, :stream_attempt, :exception], attempt, %{status: status})

    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} returned #{status}, trying fallback (stream)"
    )

    try_stream(rest, body, user_id, error)
  end

  defp handle_stream_result({:error, %Result{status: 429}} = error, attempt, rest, body, user_id) do
    CircuitBreaker.failure(attempt, retry_after(error))
    Telemetry.emit([:routing, :stream_attempt, :exception], attempt, %{status: 429})

    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} rate-limited, trying fallback (stream)"
    )

    try_stream(rest, body, user_id, error)
  end

  defp handle_stream_result({:error, _result} = error, _attempt, _rest, _body, _user_id),
    do: error

  defp retry_after({:error, %Result{retry_after_ms: retry_after_ms}}), do: retry_after_ms

  defp invoke(%Attempt{timeout_ms: nil} = attempt, function, args) do
    apply(attempt.provider, function, args)
  end

  defp invoke(%Attempt{timeout_ms: timeout_ms} = attempt, function, args) do
    task = Task.async(fn -> apply(attempt.provider, function, args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, Result.error("Provider timed out after #{timeout_ms}ms", 504, nil)}
    end
  rescue
    error in [RuntimeError, ArgumentError] ->
      {:error, Result.error(Exception.message(error), 500, nil)}
  end
end
