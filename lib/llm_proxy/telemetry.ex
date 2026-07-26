defmodule LLMProxy.Telemetry do
  @moduledoc """
  Telemetry and OpenTelemetry helpers for provider routing and execution spans.
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias LLMProxy.Providers.ReqLLM.ErrorProjection

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
    error = ErrorProjection.project(reason)
    exception_type = exception_type(reason)

    Logger.error(
      "Upstream stream failed provider=#{context.provider} model=#{context.model} " <>
        "trace_id=#{context.trace_id} status=#{error.status} code=#{error.code} " <>
        "exception=#{exception_type} reason=#{inspect(error.message)}"
    )

    safe_exception = RuntimeError.exception(error.message)

    Tracer.record_exception(safe_exception, sanitize_stacktrace(stacktrace), [
      {:"llm_proxy.exception.original_type", exception_type}
    ])

    Tracer.set_status(OpenTelemetry.status(:error, error.message))

    :telemetry.execute(
      [:llm_proxy, :routing, :stream_attempt, :exception],
      %{status: error.status, system_time: System.system_time()},
      Map.merge(context, %{
        error_code: error.code,
        error_message: error.message,
        exception_type: exception_type,
        lazy: true
      })
    )
  end

  def emit(event, attempt, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(
      [:llm_proxy | event],
      measurements,
      Map.merge(
        %{
          provider: attempt.provider.name(),
          model: attempt.model,
          timeout_ms: attempt.timeout_ms
        },
        metadata
      )
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
