defmodule LLMProxy.Accounting.UsageTrackingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LLMProxy.Accounting.UsageTracking
  alias LLMProxy.Usage

  defmodule FailingStorage do
    def record_trace(attrs), do: {:ok, attrs}

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

  test "disabled content capture does not invoke the message extractor" do
    assert :ok =
             UsageTracking.log_user_message(
               %{id: "key-1", capture_content: false},
               "model",
               "chat",
               fn ->
                 send(self(), :content_extracted)
                 "seeded-private-prompt"
               end
             )

    refute_received :content_extracted
  end

  test "tracing keeps accounting metadata but omits bodies when capture is disabled" do
    secret = "seeded-private-trace-e5ad"

    assert {:ok, trace} =
             UsageTracking.maybe_record_trace(
               %{id: "key-1", trace_requests: true, capture_content: false},
               "unknown-model",
               %{"prompt" => secret},
               %{"answer" => secret},
               Usage.new(10, 2),
               %{provider: "test", duration_ms: 12, metadata: %{"trace_id" => "trace-1"}}
             )

    assert trace.input_tokens == 10
    assert trace.output_tokens == 2
    assert trace.duration_ms == 12
    refute Map.has_key?(trace, :request_body)
    refute Map.has_key?(trace, :response_body)
    refute inspect(trace) =~ secret
  end

  test "enabled content capture stores trace bodies in the approved trace record" do
    secret = "seeded-private-trace-a91c"

    assert {:ok, trace} =
             UsageTracking.maybe_record_trace(
               %{id: "key-1", trace_requests: true, capture_content: true},
               "unknown-model",
               %{"prompt" => secret},
               %{"answer" => secret},
               Usage.new(10, 2),
               %{provider: "test", metadata: %{"trace_id" => "trace-2"}}
             )

    assert trace.request_body =~ secret
    assert trace.response_body =~ secret
  end
end
