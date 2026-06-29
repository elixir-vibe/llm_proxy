defmodule LLMProxy.Config.Catalog do
  @moduledoc """
  Boundary parser for catalog application configuration.

  The parser converts the supported operator-facing catalog shape into strict
  `LLMProxy.Catalog.Model` and `LLMProxy.Catalog.Deployment` structs. Downstream
  catalog code receives structs only.
  """

  alias LLMProxy.Catalog.{Deployment, Model}

  @spec parse(term(), term()) :: [Model.t()]
  def parse(catalog_config, models_config) do
    parse_catalog(catalog_config) ++ parse_models(models_config)
  end

  defp parse_catalog(nil), do: []
  defp parse_catalog([]), do: []
  defp parse_catalog(models) when is_list(models), do: Enum.map(models, &catalog_model!/1)

  defp parse_models(nil), do: []
  defp parse_models([]), do: []

  defp parse_models(models) when is_list(models) do
    if Keyword.keyword?(models) do
      Enum.map(models, fn {name, config} -> named_model!(name, config) end)
    else
      Enum.map(models, &operator_model!/1)
    end
  end

  defp parse_models(models) when is_map(models) do
    Enum.map(models, fn {name, config} -> named_model!(name, config) end)
  end

  defp catalog_model!(%Model{} = model), do: model

  defp catalog_model!(other) do
    raise ArgumentError,
          "catalog entries must be %LLMProxy.Catalog.Model{}, got: #{inspect(other)}"
  end

  defp named_model!(name, config) when is_list(config) do
    config
    |> Keyword.put_new(:name, model_name(name))
    |> operator_model!()
  end

  defp named_model!(name, config) when is_map(config) do
    config
    |> Map.put_new(:name, model_name(name))
    |> operator_model!()
  end

  defp operator_model!(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError, "model config must be a keyword list, got: #{inspect(config)}"
    end

    Model.new!(
      name: Keyword.fetch!(config, :name),
      hidden: Keyword.get(config, :hidden, false),
      routing_strategy: Model.routing_strategy!(Keyword.get(config, :routing, :ordered)),
      deployments: config |> Keyword.get(:routes, []) |> routes!(),
      metadata: Keyword.get(config, :metadata, %{})
    )
  end

  defp operator_model!(%{} = config) do
    Model.new!(
      name: Map.fetch!(config, :name),
      hidden: Map.get(config, :hidden, false),
      routing_strategy: Model.routing_strategy!(Map.get(config, :routing, :ordered)),
      deployments: config |> Map.get(:routes, []) |> routes!(),
      metadata: Map.get(config, :metadata, %{})
    )
  end

  defp routes!(routes) when is_list(routes), do: Enum.map(routes, &route!/1)

  defp routes!(routes) do
    raise ArgumentError, "model routes must be a list, got: #{inspect(routes)}"
  end

  defp route!(route) when is_list(route) do
    unless Keyword.keyword?(route) do
      raise ArgumentError, "route config must be a keyword list, got: #{inspect(route)}"
    end

    Deployment.new!(
      provider: route |> Keyword.fetch!(:to) |> provider_module!(),
      upstream_model: Keyword.fetch!(route, :model),
      order: Keyword.get(route, :order, 1),
      token_pool: Keyword.get(route, :token_pool),
      timeout_ms: Keyword.get(route, :timeout_ms),
      failure_threshold: Keyword.get(route, :failure_threshold),
      cooldown_ms: Keyword.get(route, :cooldown_ms),
      weight: Keyword.get(route, :weight, 1),
      metadata: Keyword.get(route, :metadata, %{})
    )
  end

  defp route!(%{} = route) do
    Deployment.new!(
      provider: route |> Map.fetch!(:to) |> provider_module!(),
      upstream_model: Map.fetch!(route, :model),
      order: Map.get(route, :order, 1),
      token_pool: Map.get(route, :token_pool),
      timeout_ms: Map.get(route, :timeout_ms),
      failure_threshold: Map.get(route, :failure_threshold),
      cooldown_ms: Map.get(route, :cooldown_ms),
      weight: Map.get(route, :weight, 1),
      metadata: Map.get(route, :metadata, %{})
    )
  end

  defp provider_module!(module) when is_atom(module) do
    cond do
      function_exported?(module, :name, 0) -> module
      module == :openai -> LLMProxy.Providers.OpenAI
      module == :openai_codex -> LLMProxy.Providers.OpenAICodex
      module == :anthropic -> LLMProxy.Providers.Anthropic
      module == :openrouter -> LLMProxy.Providers.OpenRouter
      true -> raise ArgumentError, "unknown LLMProxy provider #{inspect(module)}"
    end
  end

  defp provider_module!("openai"), do: LLMProxy.Providers.OpenAI
  defp provider_module!("openai-codex"), do: LLMProxy.Providers.OpenAICodex
  defp provider_module!("anthropic"), do: LLMProxy.Providers.Anthropic
  defp provider_module!("openrouter"), do: LLMProxy.Providers.OpenRouter

  defp provider_module!(provider) do
    raise ArgumentError, "unknown LLMProxy provider #{inspect(provider)}"
  end

  defp model_name(name) when is_atom(name), do: Atom.to_string(name)
  defp model_name(name) when is_binary(name), do: name
end
