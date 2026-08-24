defmodule LLMProxy.Providers.Execution do
  @moduledoc """
  Executes provider attempts with timeout, retry, fallback, telemetry, and circuit-breaker handling.

  On retryable errors (5xx, timeout, connection errors), tries fallback
  providers configured via `config :llm_proxy, :fallbacks`.
  Rate-limited (429) tokens are marked and the next token/provider is tried.
  """

  require Logger

  alias LLMProxy.Config
  alias LLMProxy.Protocol
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.Attempt
  alias LLMProxy.Providers.CircuitBreaker
  alias LLMProxy.Providers.Registry
  alias LLMProxy.Providers.Result
  alias LLMProxy.Providers.Routing.{Performance, Sample}
  alias LLMProxy.Stream.Event
  alias LLMProxy.Telemetry
  alias LLMProxy.Usage

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

  def call_native_attempts(attempts, %Request{} = request, user_id, api_name)
      when is_list(attempts) do
    attempts
    |> Enum.map(&Attempt.new/1)
    |> try_native(:call_native, request, user_id, api_name, nil)
  end

  def stream_native_attempts(attempts, %Request{} = request, user_id, api_name)
      when is_list(attempts) do
    attempts
    |> Enum.map(&Attempt.new/1)
    |> try_native(:stream_native, request, user_id, api_name, nil)
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
      call_body = Protocol.provider_request_body(body, attempt.provider, attempt.model)

      started_at = now_ms()

      attempt
      |> invoke(:call, [call_body, user_id])
      |> observe_call_result(attempt, body, started_at)
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

    Result.with_attempt({:ok, result}, attempt)
  end

  defp handle_call_result(
         {:error, %Result{status: status} = result} = error,
         attempt,
         rest,
         body,
         user_id
       )
       when status in @retryable_statuses do
    CircuitBreaker.failure(attempt, retry_after(error))
    Telemetry.emit([:routing, :attempt, :exception], attempt, %{status: status})

    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} returned #{status} (#{result.error}), trying fallback"
    )

    try_call(rest, body, user_id, error)
  end

  defp handle_call_result({:error, %Result{status: 429}} = error, attempt, rest, body, user_id) do
    CircuitBreaker.failure(attempt, retry_after(error))
    Telemetry.emit([:routing, :attempt, :exception], attempt, %{status: 429})
    Logger.warning("#{attempt.provider.name()}/#{attempt.model} rate-limited, trying fallback")
    try_call(rest, body, user_id, error)
  end

  defp handle_call_result({:error, %Result{} = result} = error, attempt, _rest, _body, _user_id) do
    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} failed (#{result.status}): #{result.error}"
    )

    error
  end

  defp try_stream([], _body, _user_id, nil) do
    {:error, Result.error("No healthy deployments available", 503, nil)}
  end

  defp try_stream([], _body, _user_id, last_error), do: last_error

  defp try_stream([%Attempt{} = attempt | rest], body, user_id, last_error) do
    if CircuitBreaker.available?(attempt) do
      Telemetry.emit([:routing, :stream_attempt, :start], attempt)
      stream_body = Protocol.provider_request_body(body, attempt.provider, attempt.model)

      started_at = now_ms()

      attempt
      |> invoke(:stream, [stream_body, user_id])
      |> observe_stream_result(attempt, body, started_at)
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

    Result.with_attempt({:ok, result}, attempt)
  end

  defp handle_stream_result(
         {:error, %Result{status: status} = result} = error,
         attempt,
         rest,
         body,
         user_id
       )
       when status in @retryable_statuses do
    CircuitBreaker.failure(attempt, retry_after(error))
    Telemetry.emit([:routing, :stream_attempt, :exception], attempt, %{status: status})

    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} returned #{status} (#{result.error}), trying fallback (stream)"
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

  defp handle_stream_result({:error, %Result{} = result} = error, attempt, _rest, _body, _user_id) do
    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} failed (#{result.status}) (stream): #{result.error}"
    )

    error
  end

  defp try_native([], _function, _request, _user_id, _api_name, nil) do
    {:error, Result.error("No healthy deployments available", 503, nil)}
  end

  defp try_native([], _function, _request, _user_id, _api_name, last_error), do: last_error

  defp try_native([%Attempt{} = attempt | rest], function, request, user_id, api_name, last_error) do
    cond do
      not CircuitBreaker.available?(attempt) ->
        try_native(rest, function, request, user_id, api_name, last_error)

      not function_exported?(attempt.provider, function, 2) ->
        error = unsupported_native_error(attempt, api_name)
        try_native(rest, function, request, user_id, api_name, error)

      true ->
        event = native_event(function)
        Telemetry.emit([:routing, event, :start], attempt)

        started_at = now_ms()

        attempt
        |> invoke(function, [native_attempt_body(request, attempt.model), user_id])
        |> observe_native_result(attempt, request, function, started_at)
        |> handle_native_result(attempt, rest, function, request, user_id, api_name)
    end
  end

  defp handle_native_result(
         {:ok, result},
         attempt,
         rest,
         function,
         _request,
         _user_id,
         _api_name
       ) do
    CircuitBreaker.success(attempt)
    Telemetry.emit([:routing, native_event(function), :stop], attempt)

    if rest != [] do
      Logger.info("Fallback to #{attempt.provider.name()}/#{attempt.model} succeeded (native)")
    end

    Result.with_attempt({:ok, result}, attempt)
  end

  defp handle_native_result(
         {:error, %Result{status: 429}} = error,
         attempt,
         rest,
         function,
         request,
         user_id,
         api_name
       ) do
    handle_retryable_native_error(error, attempt, rest, function, request, user_id, api_name)
  end

  defp handle_native_result(
         {:error, %Result{status: status}} = error,
         attempt,
         rest,
         function,
         request,
         user_id,
         api_name
       )
       when status in @retryable_statuses do
    handle_retryable_native_error(error, attempt, rest, function, request, user_id, api_name)
  end

  defp handle_native_result(
         {:error, %Result{} = result},
         attempt,
         _rest,
         _function,
         _request,
         _user_id,
         _api_name
       ) do
    Result.with_attempt({:error, result}, attempt)
  end

  defp handle_retryable_native_error(
         {:error, %Result{status: status} = result} = error,
         attempt,
         rest,
         function,
         request,
         user_id,
         api_name
       ) do
    CircuitBreaker.failure(attempt, retry_after(error))
    Telemetry.emit([:routing, native_event(function), :exception], attempt, %{status: status})

    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} returned #{status} (#{result.error}), trying fallback (native)"
    )

    try_native(
      rest,
      function,
      request,
      user_id,
      api_name,
      Result.with_attempt(error, attempt)
    )
  end

  defp unsupported_native_error(attempt, api_name) do
    {:error,
     Result.error(
       "Model '#{attempt.model}' does not support #{api_name}",
       400,
       nil
     )}
    |> Result.with_attempt(attempt)
  end

  defp native_attempt_body(%Request{} = request, model) do
    request
    |> Map.update!(:body, &Map.put(&1, "model", model))
    |> Map.put(:model, model)
    |> Request.native_body()
  end

  defp native_event(:stream_native), do: :native_stream_attempt
  defp native_event(:call_native), do: :native_attempt

  defp observe_call_result(
         {state, %Result{}} = result,
         attempt,
         request,
         started_at,
         event \\ :attempt
       )
       when state in [:ok, :error] do
    Performance.observe(
      attempt,
      sample(request, false, state_to_outcome(state), started_at, Usage.zero()),
      event
    )

    result
  end

  defp observe_stream_result(
         result,
         attempt,
         request,
         started_at,
         event \\ :stream_attempt
       )

  defp observe_stream_result(
         {:ok, %Result{kind: :stream, stream: stream} = result},
         attempt,
         request,
         started_at,
         event
       ) do
    {:ok, %{result | stream: instrument_stream(stream, attempt, request, started_at, event)}}
  end

  defp observe_stream_result(
         {:error, %Result{}} = result,
         attempt,
         request,
         started_at,
         event
       ) do
    Performance.observe(attempt, sample(request, true, :error, started_at, Usage.zero()), event)
    result
  end

  defp observe_native_result(result, attempt, request, :stream_native, started_at),
    do: observe_stream_result(result, attempt, request, started_at, :native_stream_attempt)

  defp observe_native_result(result, attempt, request, :call_native, started_at),
    do: observe_call_result(result, attempt, request, started_at, :native_attempt)

  defp instrument_stream(stream, attempt, request, started_at, event) do
    Stream.transform(
      stream,
      fn -> %{first_output_at: nil, usage: Usage.zero()} end,
      fn
        %Event{} = event, state ->
          first_output_at =
            if is_nil(state.first_output_at) and Event.output_delta?(event),
              do: now_ms(),
              else: state.first_output_at

          usage =
            if event.usage,
              do: Usage.merge_max(state.usage, event.usage),
              else: state.usage

          {[event], %{state | first_output_at: first_output_at, usage: usage}}

        event, state ->
          {[event], state}
      end,
      fn state ->
        Performance.observe(
          attempt,
          stream_sample(request, started_at, state.first_output_at, state.usage),
          event
        )

        {[], state}
      end,
      fn _state -> :ok end
    )
  end

  defp sample(request, stream, outcome, started_at, usage) do
    finished_at = now_ms()

    %Sample{
      operation: request.protocol,
      stream: stream,
      outcome: outcome,
      duration_ms: finished_at - started_at,
      output_tokens: usage.output_tokens,
      observed_at: finished_at
    }
  end

  defp stream_sample(request, started_at, first_output_at, usage) do
    finished_at = now_ms()
    ttft_ms = if first_output_at, do: first_output_at - started_at
    generation_ms = if first_output_at, do: finished_at - first_output_at

    %Sample{
      operation: request.protocol,
      stream: true,
      outcome: :success,
      duration_ms: finished_at - started_at,
      ttft_ms: ttft_ms,
      generation_ms: generation_ms,
      output_tokens: usage.output_tokens,
      observed_at: finished_at
    }
  end

  defp state_to_outcome(:ok), do: :success
  defp state_to_outcome(:error), do: :error

  defp retry_after({:error, %Result{retry_after_ms: retry_after_ms}}), do: retry_after_ms

  defp invoke(%Attempt{timeout_ms: nil} = attempt, function, args) do
    apply_attempt(attempt, function, args)
  rescue
    _error in [RuntimeError, ArgumentError] ->
      {:error, Result.error("Internal provider execution failed", 500, nil)}
  end

  defp invoke(%Attempt{timeout_ms: timeout_ms} = attempt, function, args) do
    task = Task.async(fn -> apply_attempt(attempt, function, args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, Result.error("Provider timed out after #{timeout_ms}ms", 504, nil)}
    end
  rescue
    _error in [RuntimeError, ArgumentError] ->
      {:error, Result.error("Internal provider execution failed", 500, nil)}
  end

  defp apply_attempt(%Attempt{provider: provider} = attempt, function, args) do
    if function_exported?(provider, function, length(args) + 1) do
      apply(provider, function, args ++ [attempt])
    else
      apply(provider, function, args)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
