defmodule LLMProxy.Accounting.UsageTrackingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LLMProxy.Accounting.UsageTracking
  alias LLMProxy.Usage

  defmodule FailingStorage do
    def update_key_usage(_key, _usage) do
      raise QuackDB.Error.new(:server_error, "accounting unavailable",
              source: :server,
              query: "INSERT secret-token"
            )
    end
  end

  setup do
    original = Application.get_env(:llm_proxy, :storage)
    Application.put_env(:llm_proxy, :storage, FailingStorage)

    on_exit(fn ->
      if original,
        do: Application.put_env(:llm_proxy, :storage, original),
        else: Application.delete_env(:llm_proxy, :storage)
    end)
  end

  test "storage exceptions are reported without failing a completed response" do
    log =
      capture_log(fn ->
        assert :ok =
                 UsageTracking.track_usage(
                   %{id: "key-1", name: "test"},
                   "openai-codex/gpt-5.6-sol",
                   Usage.new(10, 2),
                   %{
                     provider: "openai-codex",
                     metadata: %{"trace_id" => "trace-accounting"}
                   }
                 )
      end)

    assert log =~ "Usage accounting failed"
    assert log =~ "trace_id=trace-accounting"
    assert log =~ "code=quackdb_server_error"
    assert log =~ ~s(reason="accounting unavailable")
    refute log =~ "secret-token"
    refute log =~ "INSERT"
  end
end
