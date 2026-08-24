defmodule LLMProxy.Config.TOML do
  @moduledoc """
  TOML decoder for standalone LLMProxy configuration files.

  The decoder keeps TOML as data and translates only the supported top-level
  shapes into ordinary `:llm_proxy` application configuration keys. It does not
  create atoms from arbitrary TOML keys.
  """

  alias LLMProxy.Catalog.Model

  @type decoded :: [providers: map(), models: [map()]]
  @type reason :: Toml.reason()

  @spec decode(String.t(), keyword()) :: {:ok, decoded()} | {:error, reason()}
  def decode(input, opts \\ []) when is_binary(input) and is_list(opts) do
    with {:ok, data} <- Toml.decode(input, Keyword.put_new(opts, :keys, :strings)) do
      {:ok, normalize(data)}
    end
  end

  @spec decode_file(Path.t(), keyword()) :: {:ok, decoded()} | {:error, reason()}
  def decode_file(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, data} <- Toml.decode_file(path, Keyword.put_new(opts, :keys, :strings)) do
      {:ok, normalize(data)}
    end
  end

  defp normalize(data) when is_map(data) do
    []
    |> put_if_present(:providers, providers(data["providers"]))
    |> put_if_present(:models, models(data["models"] || get_in(data, ["catalog", "models"])))
    |> put_if_not_nil(:public_models, public_models(data["public_models"]))
    |> Enum.reverse()
  end

  defp put_if_present(config, _key, nil), do: config
  defp put_if_present(config, _key, []), do: config
  defp put_if_present(config, key, value), do: [{key, value} | config]
  defp put_if_not_nil(config, _key, nil), do: config
  defp put_if_not_nil(config, key, value), do: [{key, value} | config]

  defp public_models(models) when is_list(models), do: models
  defp public_models(_models), do: nil

  defp providers(nil), do: nil

  defp providers(providers) when is_map(providers) do
    Map.new(providers, fn {name, config} -> {name, provider_config(config)} end)
  end

  defp providers(_providers), do: nil

  defp provider_config(config) when is_map(config), do: normalize_keys(config)
  defp provider_config(_config), do: %{}

  defp models(nil), do: nil
  defp models(models) when is_list(models), do: Enum.map(models, &model/1)
  defp models(_models), do: nil

  defp model(model) when is_map(model) do
    model
    |> normalize_keys()
    |> normalize_model_values()
    |> Map.update(:routes, [], &routes/1)
  end

  defp model(_model), do: %{}

  defp routes(routes) when is_list(routes), do: Enum.map(routes, &route/1)
  defp routes(_routes), do: []

  defp route(route) when is_map(route) do
    route
    |> normalize_keys()
    |> normalize_route_values()
  end

  defp route(_route), do: %{}

  @known_keys %{
    "adapter" => :adapter,
    "api_keys" => :api_keys,
    "api_version" => :api_version,
    "base_url" => :base_url,
    "beta" => :beta,
    "conversion_defaults" => :conversion_defaults,
    "cooldown_ms" => :cooldown_ms,
    "failure_threshold" => :failure_threshold,
    "hidden" => :hidden,
    "http_referer" => :http_referer,
    "max_tokens" => :max_tokens,
    "metadata" => :metadata,
    "model" => :model,
    "name" => :name,
    "oauth_tokens" => :oauth_tokens,
    "order" => :order,
    "routes" => :routes,
    "routing" => :routing,
    "timeout" => :timeout,
    "timeout_ms" => :timeout_ms,
    "title" => :title,
    "to" => :to,
    "token_pool" => :token_pool,
    "weight" => :weight
  }

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized_key = normalize_key(key)
      {normalized_key, normalize_value(normalized_key, value)}
    end)
  end

  defp normalize_value(:conversion_defaults, value) when is_map(value), do: normalize_keys(value)
  defp normalize_value(_key, value), do: value

  defp normalize_model_values(%{routing: routing} = model),
    do: %{model | routing: Model.routing_strategy!(routing)}

  defp normalize_model_values(model), do: model

  defp normalize_route_values(%{timeout: timeout} = route) do
    route
    |> Map.delete(:timeout)
    |> Map.put(:timeout_ms, timeout)
  end

  defp normalize_route_values(route), do: route

  defp normalize_key(key) when is_binary(key), do: Map.fetch!(@known_keys, key)
end
