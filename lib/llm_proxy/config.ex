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
    },
    "openai-codex" => %{
      base_url: "https://chatgpt.com/backend-api",
      oauth_tokens: ""
    }
  }
  @usage_window_4h_ms :timer.hours(4)
  @usage_window_week_ms :timer.hours(24 * 7)

  def repo, do: Application.get_env(:llm_proxy, :repo, LLMProxy.Repo)
  def storage, do: Application.get_env(:llm_proxy, :storage, LLMProxy.Storage.Ecto)

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
  def fallbacks, do: Application.get_env(:llm_proxy, :fallbacks, %{})
  def max_retries, do: Application.get_env(:llm_proxy, :max_retries, 1)

  def catalog do
    configured_catalog = Application.get_env(:llm_proxy, :catalog, [])
    configured_models = Application.get_env(:llm_proxy, :models, [])

    normalize_catalog(configured_catalog) ++ normalize_models(configured_models)
  end

  def provider_config(provider) when is_atom(provider),
    do: provider |> provider_name() |> provider_config()

  def provider_config(provider) when is_binary(provider) do
    configured = Application.get_env(:llm_proxy, :providers, %{}) |> normalize_providers()
    name = provider_name(provider)

    @default_providers
    |> Map.get(name, %{})
    |> deep_merge(Map.get(configured, name, %{}))
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

  defp normalize_providers(providers) when is_list(providers) do
    providers
    |> Enum.map(fn {provider, config} -> {provider_name(provider), normalize_value(config)} end)
    |> Map.new()
  end

  defp normalize_providers(providers) when is_map(providers) do
    providers
    |> Enum.map(fn {provider, config} -> {provider_name(provider), normalize_value(config)} end)
    |> Map.new()
  end

  defp normalize_providers(_providers), do: %{}

  defp normalize_catalog(catalog) when is_list(catalog) do
    Enum.map(catalog, &normalize_catalog_model/1)
  end

  defp normalize_catalog(_catalog), do: []

  defp normalize_models(models) when is_list(models) do
    Enum.map(models, fn
      {name, config} -> normalize_named_model(name, config)
      config when is_map(config) -> normalize_catalog_model(config)
    end)
  end

  defp normalize_models(models) when is_map(models) do
    Enum.map(models, fn {name, config} -> normalize_named_model(name, config) end)
  end

  defp normalize_models(_models), do: []

  defp normalize_named_model(name, config) do
    config
    |> normalize_value()
    |> Map.put_new(:name, model_name(name))
    |> normalize_catalog_model()
  end

  defp normalize_catalog_model(model) when is_list(model),
    do: model |> Map.new() |> normalize_catalog_model()

  defp normalize_catalog_model(model) when is_map(model) do
    model = normalize_value(model)

    deployments =
      cond do
        Map.has_key?(model, :deployments) -> Map.get(model, :deployments)
        Map.has_key?(model, :routes) -> Map.get(model, :routes)
        Map.has_key?(model, :route) -> [Map.get(model, :route)]
        true -> []
      end

    model
    |> Map.drop([:routes, :route, :routing])
    |> maybe_rename(:routing_strategy, Map.get(model, :routing))
    |> Map.put(:deployments, Enum.map(List.wrap(deployments), &normalize_deployment/1))
  end

  defp normalize_deployment(deployment) when is_list(deployment),
    do: deployment |> Map.new() |> normalize_deployment()

  defp normalize_deployment(deployment) when is_map(deployment) do
    deployment = normalize_value(deployment)
    provider = Map.get(deployment, :provider) || Map.get(deployment, :to)
    upstream_model = Map.get(deployment, :upstream_model) || Map.get(deployment, :model)

    deployment
    |> Map.drop([:to, :model, :timeout])
    |> Map.put(:provider, provider_module(provider))
    |> Map.put(:upstream_model, upstream_model)
    |> maybe_rename(:timeout_ms, Map.get(deployment, :timeout))
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
    "upstream_model" => :upstream_model,
    "weight" => :weight
  }

  defp normalize_key(key) when is_binary(key), do: Map.get(@known_config_keys, key, key)
  defp normalize_key(key), do: key

  defp maybe_rename(map, _key, nil), do: map
  defp maybe_rename(map, key, value), do: Map.put(map, key, value)

  defp provider_module(module) when is_atom(module) do
    cond do
      function_exported?(module, :name, 0) -> module
      module == :openai -> LLMProxy.Providers.OpenAI
      module == :openai_codex -> LLMProxy.Providers.OpenAICodex
      module == :anthropic -> LLMProxy.Providers.Anthropic
      module == :openrouter -> LLMProxy.Providers.OpenRouter
      true -> module
    end
  end

  defp provider_module(provider) when is_binary(provider) do
    case provider_name(provider) do
      "openai" -> LLMProxy.Providers.OpenAI
      "openai-codex" -> LLMProxy.Providers.OpenAICodex
      "anthropic" -> LLMProxy.Providers.Anthropic
      "openrouter" -> LLMProxy.Providers.OpenRouter
      _other -> raise ArgumentError, "unknown LLMProxy provider #{inspect(provider)}"
    end
  end

  defp provider_module(provider), do: provider

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

  defp model_name(name) when is_atom(name), do: Atom.to_string(name)
  defp model_name(name), do: to_string(name)

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
