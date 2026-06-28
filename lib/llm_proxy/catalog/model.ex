defmodule LLMProxy.Catalog.Model do
  @moduledoc """
  Internal catalog entry for a public model alias.
  """

  alias LLMProxy.Catalog.Deployment

  @routing_strategies [:ordered, :shuffle, :round_robin, :weighted_shuffle, :lowest_cost]

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
    routing_strategy = Keyword.get(attrs, :routing_strategy, :ordered)
    validate_routing_strategy!(routing_strategy)

    %__MODULE__{
      name: Keyword.fetch!(attrs, :name),
      hidden: Keyword.get(attrs, :hidden, false),
      routing_strategy: routing_strategy,
      deployments: Keyword.get(attrs, :deployments, []),
      metadata: Keyword.get(attrs, :metadata, %{})
    }
  end

  defp validate_routing_strategy!(strategy) when strategy in @routing_strategies, do: :ok

  defp validate_routing_strategy!(strategy) do
    raise ArgumentError, "invalid catalog routing strategy #{inspect(strategy)}"
  end
end
