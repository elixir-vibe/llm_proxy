defmodule LLMProxy.Telemetry do
  @moduledoc false

  require OpenTelemetry.Tracer, as: Tracer

  def with_provider_span(provider_name, model, operation, fun) do
    Tracer.with_span "llm_proxy.provider.#{operation}",
      attributes: %{"llm.provider": provider_name, "llm.model": model} do
      fun.()
    end
  end
end
