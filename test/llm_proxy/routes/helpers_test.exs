defmodule LLMProxy.Routes.HelpersTest do
  use ExUnit.Case

  import Plug.Test

  alias LLMProxy.Routes.Helpers
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.Usage

  setup do
    TestSupport.checkout_repo()
    :ok
  end

  test "track_usage/4 records usage and spend" do
    {:ok, key, _} = Storage.create_key("tracked")

    usage = Usage.new(1000, 500)
    Helpers.track_usage(key, "gpt-4o", usage, %{duration_ms: 42, provider: "openai"})

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 1000
    assert updated_key.output_tokens == 500
    assert updated_key.total_spend_usd > 0

    [entry] = Storage.get_stats().recent_usage
    assert entry.duration_ms == 42
    assert entry.provider == "openai"
  end

  test "maybe_record_trace/6 stores traces when enabled" do
    {:ok, key, _} = Storage.create_key("traceable", %{trace_requests: true})

    Helpers.maybe_record_trace(
      key,
      "gpt-4o",
      %{"input" => "hello"},
      %{"output" => "world"},
      Usage.new(10, 5),
      %{provider: "openai", duration_ms: 11, metadata: %{"session_id" => "sess-1"}}
    )

    [trace] = Storage.get_traces(%{per_page: 10})
    assert trace.model == "gpt-4o"
    assert trace.provider == "openai"
    assert trace.session_id == "sess-1"
  end

  test "check_model_access/2 permits the master key" do
    assert :ok == Helpers.check_model_access(%{id: "master"}, "any-model")
  end

  test "log_user_message/4 skips empty messages and stores non-empty ones" do
    {:ok, key, _} = Storage.create_key("logger")

    assert :ok == Helpers.log_user_message(key, "gpt-4o", "chat", fn -> "" end)
    assert Storage.get_messages(%{per_page: 10}) == []

    Helpers.log_user_message(key, "gpt-4o", "chat", fn -> "hello" end)

    [message] = Storage.get_messages(%{per_page: 10})
    assert message.user_message == "hello"
  end

  test "send_json/3 writes json responses" do
    conn = Helpers.send_json(conn(:get, "/"), 201, %{ok: true})

    assert conn.status == 201
    assert Jason.decode!(conn.resp_body) == %{"ok" => true}
  end
end
