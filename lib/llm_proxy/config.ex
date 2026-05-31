defmodule LLMProxy.Config do
  @moduledoc false

  def master_key, do: Application.get_env(:llm_proxy, :master_key)

  def valid_master_key?(key) when is_binary(key) do
    case master_key() do
      configured when is_binary(configured) and configured != "" -> key == configured
      _ -> false
    end
  end

  def valid_master_key?(_key), do: false

  @default_token_cooldown_ms :timer.hours(4)
  @default_deployment_failure_threshold 3
  @default_deployment_cooldown_ms :timer.seconds(30)
  @default_provider_receive_timeout_ms :timer.minutes(10)
  @default_remote_timeout_ms :timer.seconds(30)
  @default_anthropic_max_tokens 4096
  @usage_window_4h_ms :timer.hours(4)
  @usage_window_week_ms :timer.hours(24 * 7)

  def public_url, do: Application.get_env(:llm_proxy, :public_url, "")
  def fallbacks, do: Application.get_env(:llm_proxy, :fallbacks, %{})
  def max_retries, do: Application.get_env(:llm_proxy, :max_retries, 1)

  def token_cooldown_ms,
    do: Application.get_env(:llm_proxy, :token_cooldown_ms, @default_token_cooldown_ms)

  def deployment_failure_threshold,
    do:
      Application.get_env(
        :llm_proxy,
        :deployment_failure_threshold,
        @default_deployment_failure_threshold
      )

  def deployment_cooldown_ms,
    do: Application.get_env(:llm_proxy, :deployment_cooldown_ms, @default_deployment_cooldown_ms)

  def provider_receive_timeout_ms,
    do:
      Application.get_env(
        :llm_proxy,
        :provider_receive_timeout_ms,
        @default_provider_receive_timeout_ms
      )

  def remote_timeout_ms,
    do: Application.get_env(:llm_proxy, :remote_timeout_ms, @default_remote_timeout_ms)

  def anthropic_max_tokens,
    do: Application.get_env(:llm_proxy, :anthropic_max_tokens, @default_anthropic_max_tokens)

  def usage_window_4h_ms, do: @usage_window_4h_ms
  def usage_window_week_ms, do: @usage_window_week_ms
end
