defmodule LLMProxy.Catalog do
  @moduledoc """
  Public model catalog for aliases and deployment metadata.
  """

  alias LLMProxy.Catalog.Model
  alias LLMProxy.Providers.Routing.{LowestCost, Ordered, RoundRobin, Shuffle, WeightedShuffle}

  @catalog_key :llm_proxy_catalog

  @spec init() :: :ok
  def init do
    load(Application.get_env(:llm_proxy, :catalog, []))
  end

  @spec load([Model.t() | map() | keyword()]) :: :ok
  def load(models) when is_list(models) do
    catalog =
      models
      |> Enum.map(&normalize_model/1)
      |> Map.new(fn %Model{name: name} = model -> {name, model} end)

    :persistent_term.put(@catalog_key, catalog)
    :ok
  end

  @spec put_model(Model.t() | map() | keyword()) :: :ok
  def put_model(model) do
    %Model{name: name} = model = normalize_model(model)
    catalog = :persistent_term.get(@catalog_key, %{})
    :persistent_term.put(@catalog_key, Map.put(catalog, name, model))
    :ok
  end

  @spec get_model(String.t()) :: Model.t() | nil
  def get_model(name) when is_binary(name) do
    @catalog_key
    |> :persistent_term.get(%{})
    |> Map.get(name)
  end

  @spec resolve(String.t()) :: {:ok, LLMProxy.Catalog.Deployment.t()} | :error
  def resolve(name) when is_binary(name) do
    case resolve_deployments(name) do
      {:ok, [deployment | _]} -> {:ok, deployment}
      _ -> :error
    end
  end

  @spec resolve_deployments(String.t()) :: {:ok, [LLMProxy.Catalog.Deployment.t()]} | :error
  def resolve_deployments(name) when is_binary(name) do
    case get_model(name) do
      %Model{deployments: []} ->
        :error

      %Model{deployments: deployments, routing_strategy: strategy} ->
        {:ok, route(strategy, name, deployments)}

      nil ->
        :error
    end
  end

  @spec all_models() :: [map()]
  def all_models do
    @catalog_key
    |> :persistent_term.get(%{})
    |> Map.values()
    |> Enum.reject(& &1.hidden)
    |> Enum.map(fn %Model{name: name, deployments: deployments} ->
      %{id: name, object: "model", owned_by: owner(deployments)}
    end)
  end

  defp normalize_model(%Model{} = model), do: model
  defp normalize_model(attrs), do: Model.new(attrs)

  defp route(:lowest_cost, _name, deployments), do: LowestCost.order(deployments)
  defp route(:round_robin, name, deployments), do: RoundRobin.order(name, deployments)
  defp route(:shuffle, _name, deployments), do: Shuffle.order(deployments)
  defp route(:weighted_shuffle, _name, deployments), do: WeightedShuffle.order(deployments)
  defp route(_strategy, _name, deployments), do: Ordered.order(deployments)

  defp owner([%{provider: provider} | _]) when is_atom(provider) do
    if function_exported?(provider, :name, 0), do: provider.name(), else: inspect(provider)
  end

  defp owner(_deployments), do: "catalog"
end
