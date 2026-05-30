defmodule LLMProxy.TelemetryTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Telemetry

  test "with_provider_span/4 returns the function result" do
    assert Telemetry.with_provider_span("openai", "gpt-4o", :call, fn -> :ok end) == :ok
  end
end
