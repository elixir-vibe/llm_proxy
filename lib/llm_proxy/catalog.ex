defmodule LLMProxy.Catalog do
  @moduledoc """
  Public model catalog for aliases and deployment metadata.
  """

  alias LLMProxy.Catalog.Model
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.Routing.{Performance, RoundRobin}

  @catalog_key :llm_proxy_catalog

  @spec init() :: :ok
  def init do
    load(LLMProxy.Config.catalog())
  end

  @spec load([Model.t()]) :: :ok
  def load(models) when is_list(models) do
    catalog = Map.new(models, fn %Model{name: name} = model -> {name, model} end)

    :persistent_term.put(@catalog_key, catalog)
    :ok
  end

  @spec put_model(Model.t()) :: :ok
  def put_model(%Model{name: name} = model) do
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

  @spec resolve_deployments(String.t(), Request.t() | nil) ::
          {:ok, [LLMProxy.Catalog.Deployment.t()]} | :error
  def resolve_deployments(name, request \\ nil) when is_binary(name) do
    case get_model(name) do
      %Model{deployments: []} ->
        :error

      %Model{deployments: deployments, routing_strategy: strategy} ->
        {:ok, route(strategy, name, deployments, request)}

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

  defp route(:latency_aware, name, deployments, %Request{} = request),
    do: Performance.order(name, deployments, request)

  defp route(:lowest_cost, _name, deployments, _request), do: order_by_lowest_cost(deployments)
  defp route(:round_robin, name, deployments, _request), do: RoundRobin.order(name, deployments)
  defp route(:shuffle, _name, deployments, _request), do: shuffle_by_order_group(deployments)

  defp route(:weighted_shuffle, _name, deployments, _request),
    do: weighted_shuffle_by_order_group(deployments)

  defp route(_strategy, _name, deployments, _request), do: Enum.sort_by(deployments, & &1.order)

  defp shuffle_by_order_group(deployments) do
    deployments
    |> Enum.group_by(& &1.order)
    |> Enum.sort_by(fn {order, _deployments} -> order end)
    |> Enum.flat_map(fn {_order, deployments} -> Enum.shuffle(deployments) end)
  end

  defp weighted_shuffle_by_order_group(deployments) do
    deployments
    |> Enum.group_by(& &1.order)
    |> Enum.sort_by(fn {order, _deployments} -> order end)
    |> Enum.flat_map(fn {_order, deployments} -> weighted_shuffle(deployments) end)
  end

  defp weighted_shuffle(deployments) do
    deployments
    |> Enum.map(fn deployment -> {deployment, weighted_priority(deployment)} end)
    |> Enum.sort_by(fn {_deployment, priority} -> priority end, :desc)
    |> Enum.map(fn {deployment, _priority} -> deployment end)
  end

  defp weighted_priority(%{weight: weight}) when is_integer(weight) and weight > 0 do
    :math.pow(:rand.uniform(), 1 / weight)
  end

  defp weighted_priority(_deployment), do: :rand.uniform()

  defp order_by_lowest_cost(deployments) do
    deployments
    |> Enum.group_by(& &1.order)
    |> Enum.sort_by(fn {order, _deployments} -> order end)
    |> Enum.flat_map(fn {_order, deployments} ->
      Enum.sort_by(deployments, &deployment_cost/1)
    end)
  end

  defp deployment_cost(%{provider: provider, upstream_model: model}) do
    case LLMProxy.ModelDB.pricing(model, provider) do
      %LLMProxy.Pricing.Rates{} = rates -> rates.input + rates.output
      nil -> :infinity
    end
  end

  defp owner([%{provider: provider} | _]) when is_atom(provider) do
    if function_exported?(provider, :name, 0), do: provider.name(), else: inspect(provider)
  end

  defp owner(_deployments), do: "catalog"
end
