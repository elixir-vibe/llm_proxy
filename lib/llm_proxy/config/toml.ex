defmodule LLMProxy.Config.TOML do
  @moduledoc """
  Strict TOML decoder for standalone LLMProxy configuration.

  The decoder translates a finite data-only schema into ordinary application
  configuration. It never creates atoms from arbitrary TOML keys and does not
  accept credentials or encryption keys.
  """

  alias LLMProxy.Catalog.Model
  alias LLMProxy.Storage.Repo.QuackDB

  @type decoded :: keyword()
  @type reason :: Toml.reason()

  @top_level_keys ~w(catalog models provider_tokens provider_usage providers routing server storage telemetry)
  @server_keys ~w(body_limit_bytes port public_url rpc_socket)
  @storage_keys ~w(database quackdb_endpoint quackdb_uri)
  @routing_keys ~w(max_retries provider_connect_timeout_ms replay_policy)
  @provider_token_keys ~w(allow_plaintext selection_strategy)
  @provider_usage_keys ~w(auto_refresh refresh_interval_ms request_timeout_ms stale_after_ms)
  @telemetry_keys ~w(otlp_endpoint)
  @catalog_keys ~w(models public_models)

  @provider_keys %{
    "adapter" => :adapter,
    "api_version" => :api_version,
    "base_url" => :base_url,
    "beta" => :beta,
    "conversion_defaults" => :conversion_defaults,
    "http_referer" => :http_referer,
    "usage_adapter" => :usage_adapter,
    "usage_auth_scheme" => :usage_auth_scheme,
    "usage_paths" => :usage_paths,
    "title" => :title,
    "token_pool" => :token_pool
  }
  @conversion_default_keys %{"max_tokens" => :max_tokens}
  @model_keys %{
    "hidden" => :hidden,
    "metadata" => :metadata,
    "name" => :name,
    "routes" => :routes,
    "routing" => :routing
  }
  @route_keys %{
    "cooldown_ms" => :cooldown_ms,
    "failure_threshold" => :failure_threshold,
    "metadata" => :metadata,
    "model" => :model,
    "order" => :order,
    "timeout" => :timeout,
    "timeout_ms" => :timeout_ms,
    "to" => :to,
    "token_pool" => :token_pool,
    "weight" => :weight
  }

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
    validate_keys!(data, @top_level_keys, "top-level")
    catalog = catalog(data["catalog"])

    llm_proxy =
      []
      |> Keyword.merge(server(data["server"]))
      |> Keyword.merge(storage(data["storage"]))
      |> Keyword.merge(routing(data["routing"]))
      |> Keyword.merge(provider_tokens(data["provider_tokens"]))
      |> Keyword.merge(provider_usage(data["provider_usage"]))
      |> put_if_present(:providers, providers(data["providers"]))
      |> put_if_present(:models, models(data["models"] || catalog[:models]))
      |> put_if_not_nil(:public_models, catalog[:public_models])

    [llm_proxy: llm_proxy] ++ telemetry(data["telemetry"])
  end

  defp server(nil), do: []

  defp server(%{} = server) do
    validate_keys!(server, @server_keys, "server")

    []
    |> put_if_present(:http, server_port(server["port"]))
    |> put_if_present(:public_url, absolute_http_url(server, "public_url"))
    |> put_if_present(:body_limit_bytes, positive_integer(server, "body_limit_bytes"))
    |> put_if_present(:rpc_socket, non_empty_string(server, "rpc_socket"))
  end

  defp server(_server), do: raise(ArgumentError, "server must be a TOML table")

  defp server_port(nil), do: nil
  defp server_port(port) when is_integer(port) and port > 0 and port <= 65_535, do: [port: port]

  defp server_port(_port),
    do: raise(ArgumentError, "server.port must be an integer from 1 to 65535")

  defp storage(nil), do: []

  defp storage(%{} = storage) do
    validate_keys!(storage, @storage_keys, "storage")

    quackdb_server =
      []
      |> put_if_present(:database, non_empty_string(storage, "database"))
      |> put_if_present(:endpoint, non_empty_string(storage, "quackdb_endpoint"))

    repo =
      []
      |> put_if_present(:uri, absolute_http_url(storage, "quackdb_uri"))

    []
    |> put_if_present(:quackdb_server, quackdb_server)
    |> put_if_present(QuackDB, repo)
  end

  defp storage(_storage), do: raise(ArgumentError, "storage must be a TOML table")

  defp routing(nil), do: []

  defp routing(%{} = routing) do
    validate_keys!(routing, @routing_keys, "routing")

    []
    |> put_if_present(:max_retries, non_negative_integer(routing, "max_retries"))
    |> put_if_present(:replay_policy, replay_policy(routing["replay_policy"]))
    |> put_if_present(
      :provider_connect_timeout_ms,
      positive_integer(routing, "provider_connect_timeout_ms")
    )
  end

  defp routing(_routing), do: raise(ArgumentError, "routing must be a TOML table")

  defp replay_policy(nil), do: nil
  defp replay_policy("safe_only"), do: :safe_only
  defp replay_policy("allow_uncertain"), do: :allow_uncertain

  defp replay_policy(_policy) do
    raise ArgumentError, "routing.replay_policy must be safe_only or allow_uncertain"
  end

  defp provider_tokens(nil), do: []

  defp provider_tokens(%{} = provider_tokens) do
    validate_keys!(provider_tokens, @provider_token_keys, "provider_tokens")

    []
    |> put_if_present(
      :provider_token_allow_plaintext,
      optional_boolean(provider_tokens, "allow_plaintext")
    )
    |> put_if_present(
      :token_selection_strategy,
      token_selection_strategy(provider_tokens["selection_strategy"])
    )
  end

  defp provider_tokens(_provider_tokens) do
    raise ArgumentError, "provider_tokens must be a TOML table"
  end

  defp token_selection_strategy(nil), do: nil
  defp token_selection_strategy("affinity"), do: :affinity
  defp token_selection_strategy("fill_first"), do: :fill_first

  defp token_selection_strategy(_strategy) do
    raise ArgumentError,
          "provider_tokens.selection_strategy must be affinity or fill_first"
  end

  defp provider_usage(nil), do: []

  defp provider_usage(%{} = provider_usage) do
    validate_keys!(provider_usage, @provider_usage_keys, "provider_usage")

    refresh_interval =
      bounded_integer(provider_usage, "refresh_interval_ms", 60_000, 3_600_000)

    []
    |> put_if_present(
      :provider_usage_auto_refresh,
      optional_boolean(provider_usage, "auto_refresh")
    )
    |> put_if_present(:provider_usage_refresh_interval_ms, refresh_interval)
    |> put_if_present(
      :provider_usage_request_timeout_ms,
      bounded_integer(provider_usage, "request_timeout_ms", 1_000, 30_000)
    )
    |> put_if_present(
      :provider_usage_stale_after_ms,
      bounded_integer(provider_usage, "stale_after_ms", refresh_interval || 300_000, 86_400_000)
    )
  end

  defp provider_usage(_provider_usage) do
    raise ArgumentError, "provider_usage must be a TOML table"
  end

  defp telemetry(nil), do: []

  defp telemetry(%{} = telemetry) do
    validate_keys!(telemetry, @telemetry_keys, "telemetry")

    case absolute_http_url(telemetry, "otlp_endpoint") do
      nil ->
        []

      endpoint ->
        [
          opentelemetry: [traces_exporter: :otlp],
          opentelemetry_exporter: [otlp_endpoint: endpoint]
        ]
    end
  end

  defp telemetry(_telemetry), do: raise(ArgumentError, "telemetry must be a TOML table")

  defp catalog(nil), do: []

  defp catalog(%{} = catalog) do
    validate_keys!(catalog, @catalog_keys, "catalog")

    []
    |> put_if_present(:models, catalog["models"])
    |> put_if_not_nil(:public_models, public_models(catalog["public_models"]))
  end

  defp catalog(_catalog), do: raise(ArgumentError, "catalog must be a TOML table")

  defp public_models(nil), do: nil

  defp public_models(models) when is_list(models) do
    if Enum.all?(models, &(is_binary(&1) and String.trim(&1) != "")) do
      Enum.uniq(models)
    else
      raise ArgumentError, "catalog.public_models must contain only non-empty model IDs"
    end
  end

  defp public_models(_models) do
    raise ArgumentError, "catalog.public_models must be an array of model IDs"
  end

  defp providers(nil), do: nil

  defp providers(%{} = providers) do
    Map.new(providers, fn
      {name, %{} = config} -> {name, normalize_map(config, @provider_keys, "provider")}
      {_name, _config} -> raise ArgumentError, "provider configuration must be a TOML table"
    end)
  end

  defp providers(_providers), do: raise(ArgumentError, "providers must be a TOML table")

  defp models(nil), do: nil
  defp models(models) when is_list(models), do: Enum.map(models, &model/1)
  defp models(_models), do: raise(ArgumentError, "models must be an array of TOML tables")

  defp model(%{} = model) do
    model
    |> normalize_map(@model_keys, "model")
    |> normalize_model_values()
    |> Map.update(:routes, [], &routes/1)
  end

  defp model(_model), do: raise(ArgumentError, "model must be a TOML table")

  defp routes(routes) when is_list(routes), do: Enum.map(routes, &route/1)
  defp routes(_routes), do: raise(ArgumentError, "model routes must be an array of TOML tables")

  defp route(%{} = route) do
    route
    |> normalize_map(@route_keys, "route")
    |> normalize_route_values()
  end

  defp route(_route), do: raise(ArgumentError, "route must be a TOML table")

  defp normalize_map(map, known_keys, section) do
    Map.new(map, fn {key, value} ->
      normalized_key = known_key!(known_keys, key, section)
      {normalized_key, normalize_value(normalized_key, value)}
    end)
  end

  defp normalize_value(:conversion_defaults, %{} = value),
    do: normalize_map(value, @conversion_default_keys, "provider conversion_defaults")

  defp normalize_value(:conversion_defaults, _value),
    do: raise(ArgumentError, "provider conversion_defaults must be a TOML table")

  defp normalize_value(:usage_adapter, "glm"), do: "glm"

  defp normalize_value(:usage_adapter, _value),
    do: raise(ArgumentError, "provider usage_adapter must be glm")

  defp normalize_value(:usage_auth_scheme, value) when value in ["raw", "bearer"], do: value

  defp normalize_value(:usage_auth_scheme, _value),
    do: raise(ArgumentError, "provider usage_auth_scheme must be raw or bearer")

  defp normalize_value(:usage_paths, paths) when is_list(paths) do
    if paths != [] and length(paths) <= 3 and length(paths) == MapSet.size(MapSet.new(paths)) and
         Enum.all?(paths, &valid_usage_path?/1) do
      paths
    else
      raise ArgumentError,
            "provider usage_paths must contain one through three distinct absolute origin paths"
    end
  end

  defp normalize_value(:usage_paths, _value) do
    raise ArgumentError,
          "provider usage_paths must contain one through three distinct absolute origin paths"
  end

  defp normalize_value(_key, value), do: value

  defp valid_usage_path?(path) when is_binary(path) do
    byte_size(path) <= 256 and String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.contains?(path, ["?", "#", "\\", "\r", "\n"])
  end

  defp valid_usage_path?(_path), do: false

  defp normalize_model_values(%{routing: routing} = model),
    do: %{model | routing: Model.routing_strategy!(routing)}

  defp normalize_model_values(model), do: model

  defp normalize_route_values(%{timeout: timeout} = route) do
    route
    |> Map.delete(:timeout)
    |> Map.put(:timeout_ms, timeout)
  end

  defp normalize_route_values(route), do: route

  defp known_key!(known_keys, key, _section) do
    case Map.fetch(known_keys, key) do
      {:ok, normalized} -> normalized
      :error -> raise ArgumentError, "unsupported TOML configuration key"
    end
  end

  defp validate_keys!(map, allowed, section) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)) do
      :ok
    else
      raise ArgumentError, "#{section} contains unsupported configuration keys"
    end
  end

  defp non_empty_string(map, key) do
    case Map.fetch(map, key) do
      :error -> nil
      {:ok, value} when is_binary(value) and value != "" -> value
      {:ok, _value} -> raise ArgumentError, "#{key} must be a non-empty string"
    end
  end

  defp positive_integer(map, key) do
    case Map.fetch(map, key) do
      :error -> nil
      {:ok, value} when is_integer(value) and value > 0 -> value
      {:ok, _value} -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp non_negative_integer(map, key) do
    case Map.fetch(map, key) do
      :error -> nil
      {:ok, value} when is_integer(value) and value >= 0 -> value
      {:ok, _value} -> raise ArgumentError, "#{key} must be a non-negative integer"
    end
  end

  defp bounded_integer(map, key, minimum, maximum) do
    case Map.fetch(map, key) do
      :error -> nil
      {:ok, value} when is_integer(value) and value >= minimum and value <= maximum -> value
      {:ok, _value} -> raise ArgumentError, "#{key} must be from #{minimum} through #{maximum}"
    end
  end

  defp optional_boolean(map, key) do
    case Map.fetch(map, key) do
      :error -> nil
      {:ok, value} when is_boolean(value) -> value
      {:ok, _value} -> raise ArgumentError, "#{key} must be a boolean"
    end
  end

  defp absolute_http_url(map, key) do
    case non_empty_string(map, key) do
      nil -> nil
      value -> validate_http_url!(value, key)
    end
  end

  defp validate_http_url!(value, key) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        value

      _uri ->
        raise ArgumentError, "#{key} must be an absolute HTTP(S) URL"
    end
  end

  defp put_if_present(config, _key, nil), do: config
  defp put_if_present(config, _key, []), do: config
  defp put_if_present(config, key, value), do: Keyword.put(config, key, value)

  defp put_if_not_nil(config, _key, nil), do: config
  defp put_if_not_nil(config, key, value), do: Keyword.put(config, key, value)
end
