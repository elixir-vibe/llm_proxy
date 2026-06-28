defmodule LLMProxy.Telemetry do
  @moduledoc """
  Telemetry and OpenTelemetry helpers for provider routing and execution spans.
  """

  require OpenTelemetry.Tracer, as: Tracer

  def with_provider_span(provider_name, model, operation, fun, attrs \\ %{}) do
    Tracer.with_span "llm_proxy.provider.#{operation}",
      attributes: Map.merge(%{"llm.provider" => provider_name, "llm.model" => model}, attrs) do
      fun.()
    end
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
end
