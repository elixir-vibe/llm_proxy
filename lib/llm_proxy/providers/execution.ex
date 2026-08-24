defmodule LLMProxy.Providers.Execution do
  @moduledoc """
  Executes bounded provider attempts with replay-safe fallback, telemetry,
  timeouts, and circuit-breaker handling.

  Proven pre-dispatch failures and refusals can use the next route. Timeouts and
  server errors require the explicit uncertain-replay compatibility policy.
  """

  require Logger

  alias LLMProxy.Config
  alias LLMProxy.Protocol
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.Attempt
  alias LLMProxy.Providers.CircuitBreaker
  alias LLMProxy.Providers.Registry
  alias LLMProxy.Providers.ReplayPolicy
  alias LLMProxy.Providers.Result
  alias LLMProxy.Telemetry

  @retryable_statuses [500, 502, 503, 504, 529]

  def call(provider, %Request{} = body, user_id, model) do
    attempts = build_attempts(provider, model)
    call_attempts(attempts, body, user_id)
  end

  def call_attempts(attempts, %Request{} = body, user_id) when is_list(attempts) do
    attempts |> Enum.map(&Attempt.new/1) |> try_call(body, user_id, budget(), nil)
  end

  def stream(provider, %Request{} = body, user_id, model) do
    attempts = build_attempts(provider, model)
    stream_attempts(attempts, body, user_id)
  end

  def stream_attempts(attempts, %Request{} = body, user_id) when is_list(attempts) do
    attempts |> Enum.map(&Attempt.new/1) |> try_stream(body, user_id, budget(), nil)
  end

  def call_native_attempts(attempts, %Request{} = request, user_id, api_name)
      when is_list(attempts) do
    attempts
    |> Enum.map(&Attempt.new/1)
    |> try_native(:call_native, request, user_id, api_name, budget(), nil)
  end

  def stream_native_attempts(attempts, %Request{} = request, user_id, api_name)
      when is_list(attempts) do
    attempts
    |> Enum.map(&Attempt.new/1)
    |> try_native(:stream_native, request, user_id, api_name, budget(), nil)
  end

  defp build_attempts(provider, model) do
    primary = Attempt.new({provider, model})
    fallbacks = Registry.get_fallbacks(model)

    [primary | fallbacks]
  end

  defp try_call([], _body, _user_id, _budget, nil) do
    {:error, Result.error("No healthy deployments available", 503, nil)}
  end

  defp try_call([], _body, _user_id, _budget, last_error), do: last_error

  defp try_call([%Attempt{} = attempt | rest], body, user_id, budget, last_error) do
    cond do
      not CircuitBreaker.available?(attempt) ->
        emit_skip(:attempt, attempt, budget, rest, :circuit_open)
        try_call(rest, body, user_id, budget, last_error)

      not budget_available?(budget) ->
        last_error || attempt_budget_error()

      true ->
        budget = use_attempt(budget)
        Telemetry.emit([:routing, :attempt, :start], attempt, %{}, attempt_metadata(budget))
        call_body = Protocol.provider_request_body(body, attempt.provider, attempt.model)

        attempt
        |> invoke(:call, [call_body, user_id])
        |> handle_call_result(attempt, rest, body, user_id, budget)
    end
  end

  defp handle_call_result({:ok, result}, attempt, rest, _body, _user_id, budget) do
    CircuitBreaker.success(attempt)
    Telemetry.emit([:routing, :attempt, :stop], attempt, %{}, attempt_metadata(budget))

    if rest != [] do
      Logger.info("Fallback to #{attempt.provider.name()}/#{attempt.model} succeeded")
    end

    Result.with_attempt({:ok, result}, attempt)
  end

  defp handle_call_result(
         {:error, %Result{} = result} = error,
         attempt,
         rest,
         body,
         user_id,
         budget
       ) do
    maybe_record_circuit_failure(attempt, error)
    decision = replay_decision(result, rest, budget)
    emit_failure(:attempt, attempt, result, budget, decision)
    log_failure(attempt, result, decision, nil)
    error = Result.with_attempt(error, attempt)

    case decision do
      {:retry, _reason} -> try_call(rest, body, user_id, budget, error)
      {:stop, _reason} -> error
    end
  end

  defp handle_call_result({:error, _result} = error, _attempt, _rest, _body, _user_id, _budget),
    do: error

  defp try_stream([], _body, _user_id, _budget, nil) do
    {:error, Result.error("No healthy deployments available", 503, nil)}
  end

  defp try_stream([], _body, _user_id, _budget, last_error), do: last_error

  defp try_stream([%Attempt{} = attempt | rest], body, user_id, budget, last_error) do
    cond do
      not CircuitBreaker.available?(attempt) ->
        emit_skip(:stream_attempt, attempt, budget, rest, :circuit_open)
        try_stream(rest, body, user_id, budget, last_error)

      not budget_available?(budget) ->
        last_error || attempt_budget_error()

      true ->
        budget = use_attempt(budget)

        Telemetry.emit(
          [:routing, :stream_attempt, :start],
          attempt,
          %{},
          attempt_metadata(budget)
        )

        stream_body = Protocol.provider_request_body(body, attempt.provider, attempt.model)

        attempt
        |> invoke(:stream, [stream_body, user_id])
        |> handle_stream_result(attempt, rest, body, user_id, budget)
    end
  end

  defp handle_stream_result({:ok, result}, attempt, rest, _body, _user_id, budget) do
    CircuitBreaker.success(attempt)
    Telemetry.emit([:routing, :stream_attempt, :stop], attempt, %{}, attempt_metadata(budget))

    if rest != [] do
      Logger.info("Fallback to #{attempt.provider.name()}/#{attempt.model} succeeded (stream)")
    end

    Result.with_attempt({:ok, result}, attempt)
  end

  defp handle_stream_result(
         {:error, %Result{} = result} = error,
         attempt,
         rest,
         body,
         user_id,
         budget
       ) do
    maybe_record_circuit_failure(attempt, error)
    decision = replay_decision(result, rest, budget)
    emit_failure(:stream_attempt, attempt, result, budget, decision)
    log_failure(attempt, result, decision, "stream")
    error = Result.with_attempt(error, attempt)

    case decision do
      {:retry, _reason} -> try_stream(rest, body, user_id, budget, error)
      {:stop, _reason} -> error
    end
  end

  defp handle_stream_result(
         {:error, _result} = error,
         _attempt,
         _rest,
         _body,
         _user_id,
         _budget
       ),
       do: error

  defp try_native([], _function, _request, _user_id, _api_name, _budget, nil) do
    {:error, Result.error("No healthy deployments available", 503, nil)}
  end

  defp try_native([], _function, _request, _user_id, _api_name, _budget, last_error),
    do: last_error

  defp try_native(
         [%Attempt{} = attempt | rest],
         function,
         request,
         user_id,
         api_name,
         budget,
         last_error
       ) do
    cond do
      not CircuitBreaker.available?(attempt) ->
        emit_skip(native_event(function), attempt, budget, rest, :circuit_open)
        try_native(rest, function, request, user_id, api_name, budget, last_error)

      not function_exported?(attempt.provider, function, 2) ->
        emit_skip(native_event(function), attempt, budget, rest, :unsupported_protocol)
        error = unsupported_native_error(attempt, api_name)
        try_native(rest, function, request, user_id, api_name, budget, error)

      not budget_available?(budget) ->
        last_error || attempt_budget_error()

      true ->
        budget = use_attempt(budget)
        event = native_event(function)
        Telemetry.emit([:routing, event, :start], attempt, %{}, attempt_metadata(budget))

        attempt
        |> invoke(function, [native_attempt_body(request, attempt.model), user_id])
        |> handle_native_result(attempt, rest, function, request, user_id, api_name, budget)
    end
  end

  defp handle_native_result(
         {:ok, result},
         attempt,
         rest,
         function,
         _request,
         _user_id,
         _api_name,
         budget
       ) do
    CircuitBreaker.success(attempt)

    Telemetry.emit(
      [:routing, native_event(function), :stop],
      attempt,
      %{},
      attempt_metadata(budget)
    )

    if rest != [] do
      Logger.info("Fallback to #{attempt.provider.name()}/#{attempt.model} succeeded (native)")
    end

    Result.with_attempt({:ok, result}, attempt)
  end

  defp handle_native_result(
         {:error, %Result{} = result} = error,
         attempt,
         rest,
         function,
         request,
         user_id,
         api_name,
         budget
       ) do
    maybe_record_circuit_failure(attempt, error)
    decision = replay_decision(result, rest, budget)
    emit_failure(native_event(function), attempt, result, budget, decision)
    log_failure(attempt, result, decision, "native")
    error = Result.with_attempt(error, attempt)

    case decision do
      {:retry, _reason} ->
        try_native(rest, function, request, user_id, api_name, budget, error)

      {:stop, _reason} ->
        error
    end
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

  defp budget, do: %{used: 0, max: Config.max_attempts()}
  defp budget_available?(%{used: used, max: max}), do: used < max
  defp use_attempt(%{used: used} = budget), do: %{budget | used: used + 1}

  defp attempt_metadata(%{used: used, max: max}) do
    %{
      attempt_number: used,
      max_attempts: max,
      replay_policy: Config.replay_policy()
    }
  end

  defp replay_decision(%Result{} = result, rest, budget) do
    ReplayPolicy.decide(
      result,
      rest != [],
      budget_available?(budget),
      Config.replay_policy()
    )
  end

  defp emit_failure(event, attempt, result, budget, {decision, reason}) do
    metadata =
      Map.merge(attempt_metadata(budget), %{
        replay_safety: result.replay_safety,
        replay_decision: decision,
        replay_reason: reason
      })

    Telemetry.emit([:routing, event, :exception], attempt, %{status: result.status}, metadata)
  end

  defp emit_skip(event, attempt, budget, rest, reason) do
    metadata =
      Map.merge(attempt_metadata(budget), %{
        replay_safety: :safe,
        replay_decision: if(rest == [], do: :stop, else: :retry),
        replay_reason: reason
      })

    Telemetry.emit([:routing, event, :skip], attempt, %{}, metadata)
  end

  defp maybe_record_circuit_failure(attempt, {:error, %Result{status: status}} = error)
       when status in [429 | @retryable_statuses] do
    CircuitBreaker.failure(attempt, retry_after(error))
  end

  defp maybe_record_circuit_failure(_attempt, _error), do: :ok

  defp log_failure(attempt, result, {decision, reason}, phase) do
    phase = if phase, do: " (#{phase})", else: ""
    action = if decision == :retry, do: ", trying fallback", else: ""

    Logger.warning(
      "#{attempt.provider.name()}/#{attempt.model} failed (#{result.status}): " <>
        "#{result.error}; replay=#{reason}#{action}#{phase}"
    )
  end

  defp attempt_budget_error do
    {:error,
     Result.error("Provider attempt budget exhausted", 503, nil, replay_safety: :forbidden)}
  end

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
      {:ok, result} ->
        result

      nil ->
        {:error,
         Result.error("Provider timed out after #{timeout_ms}ms", 504, nil,
           replay_safety: :uncertain
         )}
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
end
