defmodule LLMProxy.Telemetry do
  @moduledoc """
  Telemetry and OpenTelemetry helpers for provider routing and execution spans.
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias LLMProxy.Providers.ReqLLM.ErrorProjection

  @sensitive_markers ["authorization", "bearer ", "password=", "secret=", "token="]

  defmodule StreamContext do
    @moduledoc false

    @enforce_keys [:provider, :model, :trace_id]
    defstruct [:provider, :model, :trace_id]

    @type t :: %__MODULE__{
            provider: String.t(),
            model: String.t(),
            trace_id: String.t()
          }
  end

  def stream_context(provider, model, trace_id)
      when is_binary(provider) and is_binary(model) and is_binary(trace_id) do
    %StreamContext{provider: provider, model: model, trace_id: trace_id}
  end

  def with_provider_span(provider_name, model, operation, fun, attrs \\ %{}) do
    Tracer.with_span "llm_proxy.provider.#{operation}",
      attributes: Map.merge(%{"llm.provider" => provider_name, "llm.model" => model}, attrs) do
      fun.()
    end
  end

  def with_stream_span(parent_ctx, %StreamContext{} = context, fun) when is_function(fun, 0) do
    Tracer.with_span parent_ctx, "llm_proxy.provider.stream.consume",
      attributes: stream_attributes(context) do
      fun.()
    end
  end

  def record_stream_exception(%StreamContext{} = context, reason, stacktrace) do
    record_exception(
      "Stream pipeline failed",
      [:llm_proxy, :routing, :stream_attempt, :exception],
      context,
      reason,
      stacktrace,
      ErrorProjection.project(reason),
      %{lazy: true}
    )
  end

  def record_accounting_exception(provider, model, trace_id, reason, stacktrace) do
    context = stream_context(provider, model, trace_id)
    error = ErrorProjection.accounting_error()

    record_exception(
      "Usage accounting failed",
      [:llm_proxy, :accounting, :exception],
      context,
      reason,
      stacktrace,
      error,
      %{}
    )
  end

  def emit(event, attempt, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(
      [:llm_proxy | event],
      measurements,
      Map.merge(
        %{
          provider: attempt.provider_name || attempt.provider.name(),
          model: attempt.model,
          timeout_ms: attempt.timeout_ms
        },
        metadata
      )
    )
  end

  defp record_exception(
         log_label,
         event,
         context,
         reason,
         stacktrace,
         public_error,
         metadata
       ) do
    exception_type = exception_type(reason)
    {diagnostic_code, diagnostic_message, diagnostic_suffix} = diagnostic(reason, public_error)

    Logger.error(
      "#{log_label} provider=#{context.provider} model=#{context.model} " <>
        "trace_id=#{context.trace_id} status=#{public_error.status} code=#{diagnostic_code} " <>
        "exception=#{exception_type} reason=#{inspect(diagnostic_message)}#{diagnostic_suffix}"
    )

    Tracer.record_exception(
      RuntimeError.exception(diagnostic_message),
      sanitize_stacktrace(stacktrace),
      [
        {:"llm_proxy.exception.original_type", exception_type},
        {:"llm_proxy.error.code", diagnostic_code}
      ] ++ diagnostic_attributes(reason)
    )

    Tracer.set_status(OpenTelemetry.status(:error, diagnostic_message))

    event_metadata =
      context
      |> Map.merge(metadata)
      |> Map.merge(%{
        error_code: diagnostic_code,
        error_message: diagnostic_message,
        exception_type: exception_type,
        public_error_code: public_error.code,
        public_error_message: public_error.message
      })
      |> Map.merge(diagnostic_metadata(reason))

    :telemetry.execute(
      event,
      %{status: public_error.status, system_time: System.system_time()},
      event_metadata
    )
  end

  defp stream_attributes(context) do
    %{
      "llm.provider" => context.provider,
      "llm.model" => context.model,
      "llm_proxy.trace_id" => context.trace_id,
      "llm_proxy.stream.phase" => "consume"
    }
  end

  defp diagnostic(%QuackDB.Error{} = reason, _public_error) do
    code = "quackdb_#{reason.code || :unknown}"
    message = safe_diagnostic_message(reason.message, code)
    suffix = " source=#{reason.source || :unknown} retriable=#{reason.retriable? == true}"
    {code, message, suffix}
  end

  defp diagnostic(_reason, public_error),
    do: {public_error.code, public_error.message, ""}

  defp diagnostic_attributes(%QuackDB.Error{} = reason) do
    [
      {:"llm_proxy.storage.code", to_string(reason.code || :unknown)},
      {:"llm_proxy.storage.source", to_string(reason.source || :unknown)},
      {:"llm_proxy.storage.retriable", reason.retriable? == true}
    ]
  end

  defp diagnostic_attributes(_reason), do: []

  defp diagnostic_metadata(%QuackDB.Error{} = reason) do
    %{
      storage_code: to_string(reason.code || :unknown),
      storage_retriable: reason.retriable? == true,
      storage_source: to_string(reason.source || :unknown)
    }
  end

  defp diagnostic_metadata(_reason), do: %{}

  defp safe_diagnostic_message(message, fallback) when is_binary(message) do
    normalized = message |> String.split() |> Enum.join(" ") |> String.slice(0, 500)
    downcased = String.downcase(normalized)

    if Enum.any?(@sensitive_markers, &String.contains?(downcased, &1)),
      do: fallback,
      else: normalized
  end

  defp safe_diagnostic_message(_message, fallback), do: fallback

  defp sanitize_stacktrace(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, arguments, location} when is_list(arguments) ->
        {module, function, length(arguments), location}

      frame ->
        frame
    end)
  end

  defp exception_type(%{__struct__: module}) when is_atom(module), do: inspect(module)
  defp exception_type(_reason), do: "unknown"
end
