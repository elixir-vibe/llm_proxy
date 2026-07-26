defmodule LLMProxy.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LLMProxy.Telemetry
  alias ReqLLM.Error.API.Request, as: APIRequestError
  alias ReqLLM.Error.API.Stream, as: APIStreamError

  test "with_provider_span/4 returns the function result" do
    assert Telemetry.with_provider_span("openai", "gpt-4o", :call, fn -> :ok end) == :ok
  end

  test "local storage failures log safe structured diagnostics without query contents" do
    error =
      QuackDB.Error.new(:transaction_conflict, "Conflict on usage_log",
        source: :server,
        retriable?: true,
        query: "INSERT secret-token"
      )

    log =
      capture_log(fn ->
        Telemetry.record_stream_exception(
          Telemetry.stream_context("openai-codex", "gpt-5.6-sol", "trace-storage"),
          error,
          []
        )
      end)

    assert log =~ "Stream pipeline failed"
    assert log =~ "code=quackdb_transaction_conflict"
    assert log =~ ~s(reason="Conflict on usage_log")
    assert log =~ "source=server"
    assert log =~ "retriable=true"
    refute log =~ "secret-token"
    refute log =~ "INSERT"
  end

  test "stream exception logging excludes upstream headers and exception internals" do
    request_error =
      APIRequestError.exception(
        reason: "quota exhausted",
        status: 403,
        response_body: %{
          "message" => "Quota exhausted. Upgrade your plan.",
          "type" => "access_terminated_error"
        },
        headers: [{"authorization", "secret-token"}, {"set-cookie", "secret-cookie"}],
        provider_code: "access_terminated_error",
        retryable: false
      )

    stream_error =
      APIStreamError.exception(
        reason: "Stream failed: #{inspect(request_error)}",
        cause: request_error
      )

    log =
      capture_log(fn ->
        Telemetry.record_stream_exception(
          Telemetry.stream_context("openai-codex", "gpt-5.6-sol", "trace-safe"),
          stream_error,
          []
        )
      end)

    assert log =~ "Quota exhausted. Upgrade your plan."
    assert log =~ "trace_id=trace-safe"
    refute log =~ "secret-token"
    refute log =~ "secret-cookie"
    refute log =~ "%ReqLLM.Error"
    refute log =~ "headers:"
  end
end
