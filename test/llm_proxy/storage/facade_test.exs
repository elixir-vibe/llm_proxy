defmodule LLMProxy.Storage.FacadeTest do
  use ExUnit.Case, async: false

  defmodule Adapter do
    @behaviour LLMProxy.Storage.Adapter

    def create_key(name, opts), do: {:ok, %{name: name, opts: opts}, "raw"}
    def find_key(raw_key), do: %{raw_key: raw_key}
    def list_keys(opts), do: [opts]
    def delete_key(id), do: {:ok, id}
    def update_key_usage(key, usage), do: {key, usage}
    def update_key_quota(id, quota_attrs), do: {:ok, {id, quota_attrs}}
    def update_key_models(id, allowed_models), do: {:ok, {id, allowed_models}}
    def check_model_access(_key, _model), do: :ok
    def record_usage(attrs), do: {:ok, attrs}
    def get_usage_in_window(_key_id, _window_ms), do: %{input: 0, output: 0}
    def get_message_count_in_window(_key_id, _window_ms), do: 0
    def get_cache_ratio_in_window(_key_id, _window_ms), do: {1.0, 0}
    def check_quota(_key), do: :ok
    def record_service_usage(attrs), do: {:ok, attrs}
    def get_service_usage_in_window(_key_id, _service, _window_ms), do: 0
    def check_service_quota(_key, _service), do: :ok
    def get_tokens(_provider, _kind), do: []
    def list_tokens(opts), do: [opts]
    def add_token(provider, kind, token, opts), do: {:ok, {provider, kind, token, opts}}
    def remove_token(id), do: {:ok, id}
    def set_token_enabled(id, enabled), do: {:ok, {id, enabled}}
    def update_token_proxy(id, proxy), do: {:ok, {id, proxy}}
    def update_token_oauth(id, attrs), do: {:ok, {id, attrs}}
    def seed_tokens_from_env(_entries), do: :ok
    def log_message(attrs), do: {:ok, attrs}
    def get_messages(opts), do: [opts]
    def get_stats, do: %{ok: true}
    def record_trace(attrs), do: {:ok, attrs}
    def get_traces(opts), do: [opts]
    def get_trace(id), do: %{id: id}
    def record_trace_feedback(attrs), do: {:ok, attrs}
    def list_trace_feedback(id), do: [id]
    def get_trace_feedback(id), do: [id]
    def find_trace_by_request_id(id), do: %{request_id: id}
    def get_daily_stats(opts), do: [opts]
  end

  setup do
    original = Application.get_env(:llm_proxy, :storage)
    Application.put_env(:llm_proxy, :storage, Adapter)

    on_exit(fn ->
      if original do
        Application.put_env(:llm_proxy, :storage, original)
      else
        Application.delete_env(:llm_proxy, :storage)
      end
    end)
  end

  test "delegates to configured storage adapter" do
    assert {:ok, %{name: "user", opts: %{trace_requests: true}}, "raw"} =
             LLMProxy.Storage.create_key("user", %{trace_requests: true})

    assert LLMProxy.Storage.find_trace_by_request_id("req-1") == %{request_id: "req-1"}
    assert LLMProxy.Storage.get_stats() == %{ok: true}
  end
end
