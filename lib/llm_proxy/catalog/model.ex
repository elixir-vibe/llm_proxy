defmodule LLMProxy.Catalog.Model do
  @moduledoc """
  Internal catalog entry for a public model alias.
  """

  alias LLMProxy.Catalog.Deployment

  @routing_strategies [:ordered, :shuffle, :round_robin, :weighted_shuffle, :lowest_cost]
  @routing_strategy_names Map.new(@routing_strategies, &{Atom.to_string(&1), &1})

  @enforce_keys [:name]
  defstruct name: nil, hidden: false, routing_strategy: :ordered, deployments: [], metadata: %{}

  @type routing_strategy :: :ordered | :shuffle | :round_robin | :weighted_shuffle | :lowest_cost
  @type t :: %__MODULE__{
          name: String.t(),
          hidden: boolean(),
          routing_strategy: routing_strategy(),
          deployments: [Deployment.t()],
          metadata: map()
        }

  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    name = Keyword.fetch!(attrs, :name)
    hidden = Keyword.get(attrs, :hidden, false)
    routing_strategy = attrs |> Keyword.get(:routing_strategy, :ordered) |> routing_strategy!()
    deployments = Keyword.get(attrs, :deployments, [])
    metadata = Keyword.get(attrs, :metadata, %{})

    validate_name!(name)
    validate_hidden!(hidden)
    validate_deployments!(deployments)
    validate_metadata!(metadata)

    %__MODULE__{
      name: name,
      hidden: hidden,
      routing_strategy: routing_strategy,
      deployments: deployments,
      metadata: metadata
    }
  end

  defp validate_name!(name) when is_binary(name) and name != "", do: :ok

  defp validate_name!(name) do
    raise ArgumentError, "catalog model name must be a non-empty string, got: #{inspect(name)}"
  end

  defp validate_hidden!(hidden) when is_boolean(hidden), do: :ok

  defp validate_hidden!(hidden) do
    raise ArgumentError, "catalog model hidden must be a boolean, got: #{inspect(hidden)}"
  end

  defp validate_deployments!(deployments) when is_list(deployments) do
    Enum.each(deployments, fn
      %Deployment{} ->
        :ok

      deployment ->
        raise ArgumentError,
              "catalog model deployments must contain Deployment structs, got: #{inspect(deployment)}"
    end)
  end

  defp validate_deployments!(deployments) do
    raise ArgumentError, "catalog model deployments must be a list, got: #{inspect(deployments)}"
  end

  defp validate_metadata!(metadata) when is_map(metadata), do: :ok

  defp validate_metadata!(metadata) do
    raise ArgumentError, "catalog model metadata must be a map, got: #{inspect(metadata)}"
  end

  @spec routing_strategy!(atom() | String.t()) :: routing_strategy()
  def routing_strategy!(strategy) when strategy in @routing_strategies, do: strategy

  def routing_strategy!(strategy)
      when is_binary(strategy) and is_map_key(@routing_strategy_names, strategy),
      do: Map.fetch!(@routing_strategy_names, strategy)

  def routing_strategy!(strategy) do
    raise ArgumentError, "invalid catalog routing strategy #{inspect(strategy)}"
  end
end
