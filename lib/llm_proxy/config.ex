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
  @default_providers %{
    "anthropic" => %{
      base_url: "https://api.anthropic.com/v1",
      api_version: "2023-06-01",
      beta: "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14",
      conversion_defaults: %{max_tokens: 4096}
    },
    "openai" => %{base_url: "https://api.openai.com/v1"},
    "openrouter" => %{
      base_url: "https://openrouter.ai/api/v1",
      http_referer: "",
      title: "LLM Proxy"
    }
  }
  @usage_window_4h_ms :timer.hours(4)
  @usage_window_week_ms :timer.hours(24 * 7)

  def repo, do: Application.get_env(:llm_proxy, :repo, LLMProxy.Repo)
  def public_url, do: Application.get_env(:llm_proxy, :public_url, "")
  def fallbacks, do: Application.get_env(:llm_proxy, :fallbacks, %{})
  def max_retries, do: Application.get_env(:llm_proxy, :max_retries, 1)

  def provider_config(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> provider_config()

  def provider_config(provider) when is_binary(provider) do
    configured = Application.get_env(:llm_proxy, :providers, %{})

    @default_providers
    |> Map.get(provider, %{})
    |> deep_merge(Map.get(configured, provider, %{}))
  end

  def provider_value(provider, key), do: provider_value(provider, key, nil)

  def provider_value(provider, key, default) do
    provider
    |> provider_config()
    |> Map.get(key, default)
  end

  def provider_conversion_default(provider, key),
    do: provider_conversion_default(provider, key, nil)

  def provider_conversion_default(provider, key, default) do
    provider
    |> provider_config()
    |> Map.get(:conversion_defaults, %{})
    |> Map.get(key, default)
  end

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

  def usage_window_4h_ms, do: @usage_window_4h_ms
  def usage_window_week_ms, do: @usage_window_week_ms

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end
end
