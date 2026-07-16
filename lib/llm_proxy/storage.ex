defmodule LLMProxy.Storage do
  @moduledoc """
  Public persistence facade for keys, usage, quotas, tokens, traces, and feedback.
  """

  def create_key(name, opts \\ %{}), do: adapter().create_key(name, opts)
  def find_key(raw_key), do: adapter().find_key(raw_key)
  def list_keys(opts \\ %{}), do: adapter().list_keys(opts)
  def delete_key(id), do: adapter().delete_key(id)
  def update_key_usage(key, usage), do: adapter().update_key_usage(key, usage)
  def update_key_quota(id, quota_attrs), do: adapter().update_key_quota(id, quota_attrs)
  def update_key_models(id, allowed_models), do: adapter().update_key_models(id, allowed_models)
  def check_model_access(key, model), do: adapter().check_model_access(key, model)

  def record_usage(attrs), do: adapter().record_usage(attrs)
  def get_usage_in_window(key_id, window_ms), do: adapter().get_usage_in_window(key_id, window_ms)

  def get_message_count_in_window(key_id, window_ms),
    do: adapter().get_message_count_in_window(key_id, window_ms)

  def get_cache_ratio_in_window(key_id, window_ms),
    do: adapter().get_cache_ratio_in_window(key_id, window_ms)

  def check_quota(key), do: adapter().check_quota(key)

  def record_service_usage(attrs), do: adapter().record_service_usage(attrs)

  def get_service_usage_in_window(key_id, service, window_ms),
    do: adapter().get_service_usage_in_window(key_id, service, window_ms)

  def check_service_quota(key, service), do: adapter().check_service_quota(key, service)

  def get_tokens(provider, kind), do: adapter().get_tokens(provider, kind)
  def list_tokens(opts \\ %{}), do: adapter().list_tokens(opts)

  def add_token(provider, kind, token, opts \\ %{}),
    do: adapter().add_token(provider, kind, token, opts)

  def remove_token(id), do: adapter().remove_token(id)
  def set_token_enabled(id, enabled), do: adapter().set_token_enabled(id, enabled)
  def update_token_proxy(id, proxy), do: adapter().update_token_proxy(id, proxy)
  def update_token_oauth(id, attrs), do: adapter().update_token_oauth(id, attrs)
  def seed_tokens_from_env(entries), do: adapter().seed_tokens_from_env(entries)

  def log_message(attrs), do: adapter().log_message(attrs)
  def update_message_usage(id, usage), do: adapter().update_message_usage(id, usage)
  def get_messages(opts \\ %{}), do: adapter().get_messages(opts)
  def get_stats(opts \\ %{}), do: adapter().get_stats(opts)

  def record_trace(attrs), do: adapter().record_trace(attrs)
  def get_traces(opts \\ %{}), do: adapter().get_traces(opts)
  def get_trace(id), do: adapter().get_trace(id)
  def record_trace_feedback(attrs), do: adapter().record_trace_feedback(attrs)

  def list_trace_feedback(trace_or_request_id),
    do: adapter().list_trace_feedback(trace_or_request_id)

  def get_trace_feedback(trace_id), do: adapter().get_trace_feedback(trace_id)
  def find_trace_by_request_id(request_id), do: adapter().find_trace_by_request_id(request_id)

  def get_daily_stats(opts \\ %{}), do: adapter().get_daily_stats(opts)

  defp adapter, do: LLMProxy.Config.storage()
end
