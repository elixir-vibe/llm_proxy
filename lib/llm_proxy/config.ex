defmodule LLMProxy.Config do
  @moduledoc """
  Runtime accessors and normalization helpers for LLMProxy application configuration.
  """

  alias LLMProxy.Config.Catalog
  alias LLMProxy.Config.ProviderUsage, as: ProviderUsageConfig
  alias LLMProxy.TokenPool.Cooldown

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
  @default_provider_connect_timeout_ms :timer.seconds(10)
  @default_provider_receive_timeout_ms :timer.minutes(10)
  @default_remote_timeout_ms :timer.seconds(30)
  @default_provider_usage_refresh_interval_ms :timer.minutes(5)
  @minimum_provider_usage_refresh_interval_ms :timer.minutes(1)
  @maximum_provider_usage_refresh_interval_ms :timer.hours(1)
  @default_provider_usage_request_timeout_ms :timer.seconds(10)
  @minimum_provider_usage_request_timeout_ms :timer.seconds(1)
  @maximum_provider_usage_request_timeout_ms :timer.seconds(30)
  @default_admin_provider_usage_poll_interval_ms :timer.minutes(1)
  @minimum_admin_provider_usage_poll_interval_ms :timer.seconds(15)
  @maximum_admin_provider_usage_poll_interval_ms :timer.hours(1)
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
    },
    "openai-codex" => %{
      base_url: "https://chatgpt.com/backend-api",
      oauth_tokens: ""
    }
  }
  @usage_window_4h_ms :timer.hours(4)
  @usage_window_week_ms :timer.hours(24 * 7)

  def repo, do: Application.get_env(:llm_proxy, :repo, LLMProxy.Storage.Repo.SQLite)
  def storage, do: Application.get_env(:llm_proxy, :storage, LLMProxy.Storage.Ecto)

  def provider_token_codec do
    case Application.fetch_env(:llm_proxy, :provider_token_codec) do
      {:ok, codec} -> codec
      :error -> built_in_provider_token_codec()
    end
  end

  def provider_token_allow_plaintext? do
    Application.get_env(:llm_proxy, :provider_token_allow_plaintext, true)
  end

  defp built_in_provider_token_codec do
    keyring = Application.get_env(:llm_proxy, :provider_token_keyring)
    allow_plaintext = provider_token_allow_plaintext?()

    if is_nil(keyring) and allow_plaintext == true do
      LLMProxy.Provider.TokenCodec.Plaintext
    else
      {LLMProxy.Provider.TokenCodec.AESGCM,
       active_key_id: keyring_value(keyring, :active_key_id),
       keys: keyring_value(keyring, :keys, %{}),
       allow_plaintext: allow_plaintext}
    end
  end

  defp keyring_value(keyring, key, default \\ nil)

  defp keyring_value(keyring, key, default) when is_map(keyring) do
    Map.get(keyring, key, Map.get(keyring, Atom.to_string(key), default))
  end

  defp keyring_value(_keyring, _key, default), do: default

  def quackdb_server_options do
    Application.get_env(:llm_proxy, :quackdb_server, [])
  end

  def http_enabled?, do: Application.get_env(:llm_proxy, :http_enabled, true)

  def http_port do
    :llm_proxy
    |> Application.get_env(:http, [])
    |> Keyword.get(:port, 4000)
  end

  def rpc_socket, do: Application.get_env(:llm_proxy, :rpc_socket)

  def public_url, do: Application.get_env(:llm_proxy, :public_url, "")
  def provider_key_seeds, do: Application.get_env(:llm_proxy, :provider_key_seeds, %{})
  def fallbacks, do: Application.get_env(:llm_proxy, :fallbacks, %{})

  def max_retries do
    case Application.get_env(:llm_proxy, :max_retries, 1) do
      retries when is_integer(retries) and retries >= 0 ->
        retries

      value ->
        raise ArgumentError, ":max_retries must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  def max_attempts, do: max_retries() + 1

  def replay_policy do
    case Application.get_env(:llm_proxy, :replay_policy, :safe_only) do
      policy when policy in [:safe_only, :allow_uncertain] ->
        policy

      value ->
        raise ArgumentError,
              ":replay_policy must be :safe_only or :allow_uncertain, got: #{inspect(value)}"
    end
  end

  def public_models do
    case Application.get_env(:llm_proxy, :public_models) do
      nil ->
        nil

      models when is_list(models) ->
        validate_public_models!(models)

      value ->
        raise ArgumentError, ":public_models must be a list of model IDs, got: #{inspect(value)}"
    end
  end

  def body_limit_bytes do
    case Application.get_env(:llm_proxy, :body_limit_bytes, 32_000_000) do
      bytes when is_integer(bytes) and bytes > 0 ->
        bytes

      value ->
        raise ArgumentError,
              ":body_limit_bytes must be a positive integer, got: #{inspect(value)}"
    end
  end

  def catalog do
    configured_catalog = Application.get_env(:llm_proxy, :catalog, [])
    configured_models = Application.get_env(:llm_proxy, :models, [])

    Catalog.parse(configured_catalog, configured_models)
  end

  def provider_config(provider) when is_atom(provider),
    do: provider |> provider_name() |> provider_config()

  def provider_config(provider) when is_binary(provider) do
    configured = configured_providers()
    name = provider_name(provider)
    provider_config = Map.get(configured, name, %{})

    @default_providers
    |> Map.get(name, %{})
    |> deep_merge(provider_config)
    |> default_openrouter_referer(name, provider_config)
  end

  @doc false
  def configured_providers do
    Application.get_env(:llm_proxy, :providers, %{}) |> normalize_providers()
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

  def token_cooldown_ms do
    :llm_proxy
    |> Application.get_env(:token_cooldown_ms, @default_token_cooldown_ms)
    |> Cooldown.duration!()
  end

  def token_selection_strategy do
    case Application.get_env(:llm_proxy, :token_selection_strategy, :affinity) do
      strategy when strategy in [:affinity, :fill_first] ->
        strategy

      value ->
        raise ArgumentError,
              ":token_selection_strategy must be :affinity or :fill_first, got: #{inspect(value)}"
    end
  end

  def deployment_failure_threshold,
    do:
      Application.get_env(
        :llm_proxy,
        :deployment_failure_threshold,
        @default_deployment_failure_threshold
      )

  def deployment_cooldown_ms,
    do: Application.get_env(:llm_proxy, :deployment_cooldown_ms, @default_deployment_cooldown_ms)

  def provider_connect_timeout_ms do
    case Application.get_env(
           :llm_proxy,
           :provider_connect_timeout_ms,
           @default_provider_connect_timeout_ms
         ) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      value ->
        raise ArgumentError,
              ":provider_connect_timeout_ms must be a positive integer, got: #{inspect(value)}"
    end
  end

  def provider_receive_timeout_ms,
    do:
      Application.get_env(
        :llm_proxy,
        :provider_receive_timeout_ms,
        @default_provider_receive_timeout_ms
      )

  def remote_timeout_ms,
    do: Application.get_env(:llm_proxy, :remote_timeout_ms, @default_remote_timeout_ms)

  def provider_usage_auto_refresh? do
    case Application.get_env(:llm_proxy, :provider_usage_auto_refresh, true) do
      value when is_boolean(value) ->
        value

      value ->
        raise ArgumentError,
              ":provider_usage_auto_refresh must be a boolean, got: #{inspect(value)}"
    end
  end

  def provider_usage_refresh_interval_ms do
    bounded_integer!(
      :provider_usage_refresh_interval_ms,
      Application.get_env(
        :llm_proxy,
        :provider_usage_refresh_interval_ms,
        @default_provider_usage_refresh_interval_ms
      ),
      @minimum_provider_usage_refresh_interval_ms,
      @maximum_provider_usage_refresh_interval_ms
    )
  end

  def provider_usage_request_timeout_ms do
    bounded_integer!(
      :provider_usage_request_timeout_ms,
      Application.get_env(
        :llm_proxy,
        :provider_usage_request_timeout_ms,
        @default_provider_usage_request_timeout_ms
      ),
      @minimum_provider_usage_request_timeout_ms,
      @maximum_provider_usage_request_timeout_ms
    )
  end

  def provider_usage_stale_after_ms do
    default = max(provider_usage_refresh_interval_ms() * 2, :timer.minutes(10))

    bounded_integer!(
      :provider_usage_stale_after_ms,
      Application.get_env(:llm_proxy, :provider_usage_stale_after_ms, default),
      provider_usage_refresh_interval_ms(),
      :timer.hours(24)
    )
  end

  def admin_provider_usage_poll_interval_ms do
    bounded_integer!(
      :admin_provider_usage_poll_interval_ms,
      Application.get_env(
        :llm_proxy,
        :admin_provider_usage_poll_interval_ms,
        @default_admin_provider_usage_poll_interval_ms
      ),
      @minimum_admin_provider_usage_poll_interval_ms,
      @maximum_admin_provider_usage_poll_interval_ms
    )
  end

  def usage_window_4h_ms, do: @usage_window_4h_ms
  def usage_window_week_ms, do: @usage_window_week_ms

  defp validate_public_models!(models) do
    if Enum.all?(models, &(is_binary(&1) and String.trim(&1) != "")) do
      Enum.uniq(models)
    else
      raise ArgumentError, ":public_models must contain only non-empty model IDs"
    end
  end

  defp normalize_providers(providers) when is_list(providers) or is_map(providers) do
    providers
    |> Enum.map(&normalize_provider/1)
    |> Map.new()
  end

  defp normalize_providers(providers) do
    raise ArgumentError, ":providers must be a keyword list or map, got: #{inspect(providers)}"
  end

  defp normalize_provider({provider, config}) do
    case normalize_value(config) do
      %{} = normalized ->
        {provider_name(provider), validate_provider_usage!(provider, normalized)}

      value ->
        raise ArgumentError, "provider configuration must be a map, got: #{inspect(value)}"
    end
  end

  defp validate_provider_usage!(provider, config) do
    validate_usage_adapter!(provider, Map.get(config, :usage_adapter))
    validate_usage_auth_scheme!(provider, Map.get(config, :usage_auth_scheme))
    validate_usage_paths!(provider, Map.get(config, :usage_paths))
    config
  end

  defp validate_usage_adapter!(_provider, nil), do: :ok
  defp validate_usage_adapter!(_provider, "glm"), do: :ok

  defp validate_usage_adapter!(provider, value) do
    raise ArgumentError,
          "provider #{inspect(provider)} usage_adapter must be \"glm\", got: #{inspect(value)}"
  end

  defp validate_usage_auth_scheme!(_provider, nil), do: :ok
  defp validate_usage_auth_scheme!(_provider, value) when value in ["raw", "bearer"], do: :ok

  defp validate_usage_auth_scheme!(provider, value) do
    raise ArgumentError,
          "provider #{inspect(provider)} usage_auth_scheme must be \"raw\" or \"bearer\", got: #{inspect(value)}"
  end

  defp validate_usage_paths!(_provider, nil), do: :ok

  defp validate_usage_paths!(provider, paths) when is_list(paths) do
    unless paths != [] and length(paths) <= 3 and
             length(paths) == MapSet.size(MapSet.new(paths)) and
             Enum.all?(paths, &ProviderUsageConfig.valid_path?/1) do
      raise ArgumentError,
            "provider #{inspect(provider)} usage_paths must contain one through three distinct absolute origin paths"
    end
  end

  defp validate_usage_paths!(provider, _paths) do
    raise ArgumentError,
          "provider #{inspect(provider)} usage_paths must contain one through three distinct absolute origin paths"
  end

  defp normalize_value(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {key, nested} -> {normalize_key(key), normalize_value(nested)} end)
      |> Map.new()
    else
      Enum.map(value, &normalize_value/1)
    end
  end

  defp normalize_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {normalize_key(key), normalize_value(nested)} end)
    |> Map.new()
  end

  defp normalize_value(value), do: value

  @known_config_keys %{
    "adapter" => :adapter,
    "api_keys" => :api_keys,
    "api_version" => :api_version,
    "base_url" => :base_url,
    "beta" => :beta,
    "conversion_defaults" => :conversion_defaults,
    "cooldown_ms" => :cooldown_ms,
    "deployments" => :deployments,
    "failure_threshold" => :failure_threshold,
    "hidden" => :hidden,
    "http_referer" => :http_referer,
    "metadata" => :metadata,
    "model" => :model,
    "name" => :name,
    "oauth_tokens" => :oauth_tokens,
    "order" => :order,
    "provider" => :provider,
    "route" => :route,
    "routes" => :routes,
    "routing" => :routing,
    "routing_strategy" => :routing_strategy,
    "timeout" => :timeout,
    "timeout_ms" => :timeout_ms,
    "title" => :title,
    "to" => :to,
    "token_pool" => :token_pool,
    "usage_adapter" => :usage_adapter,
    "usage_auth_scheme" => :usage_auth_scheme,
    "usage_paths" => :usage_paths,
    "upstream_model" => :upstream_model,
    "weight" => :weight
  }

  defp normalize_key(key) when is_binary(key), do: Map.get(@known_config_keys, key, key)
  defp normalize_key(key), do: key

  defp provider_name(provider) when is_atom(provider) do
    case provider do
      LLMProxy.Providers.OpenAI -> "openai"
      LLMProxy.Providers.OpenAICodex -> "openai-codex"
      LLMProxy.Providers.Anthropic -> "anthropic"
      LLMProxy.Providers.OpenRouter -> "openrouter"
      :openai_codex -> "openai-codex"
      other -> other |> Atom.to_string() |> String.replace("_", "-")
    end
  end

  defp provider_name(provider) when is_binary(provider), do: String.replace(provider, "_", "-")

  defp default_openrouter_referer(config, "openrouter", configured) do
    if Map.has_key?(configured, :http_referer) do
      config
    else
      Map.put(config, :http_referer, public_url())
    end
  end

  defp default_openrouter_referer(config, _name, _configured), do: config

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp bounded_integer!(_name, value, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: value

  defp bounded_integer!(name, value, minimum, maximum) do
    raise ArgumentError,
          ":#{name} must be an integer from #{minimum} through #{maximum}, got: #{inspect(value)}"
  end
end
