defmodule LLMProxy.Catalog.Model do
  @moduledoc false

  alias LLMProxy.Catalog.Deployment

  defstruct [:name, hidden: false, routing_strategy: :ordered, deployments: [], metadata: %{}]

  @type routing_strategy :: :ordered | :shuffle | :round_robin | :weighted_shuffle | :lowest_cost
  @type t :: %__MODULE__{
          name: String.t(),
          hidden: boolean(),
          routing_strategy: routing_strategy(),
          deployments: [Deployment.t()],
          metadata: map()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      name: fetch!(attrs, :name, "name"),
      hidden: get(attrs, :hidden, "hidden", false),
      routing_strategy:
        routing_strategy(get(attrs, :routing_strategy, "routing_strategy", :ordered)),
      deployments: attrs |> get(:deployments, "deployments", []) |> Enum.map(&Deployment.new/1),
      metadata: get(attrs, :metadata, "metadata", %{})
    }
  end

  defp fetch!(attrs, atom_key, string_key) do
    Map.get(attrs, atom_key) || Map.fetch!(attrs, string_key)
  end

  defp get(attrs, atom_key, string_key, default) do
    Map.get(attrs, atom_key, Map.get(attrs, string_key, default))
  end

  defp routing_strategy(strategy)
       when strategy in [:shuffle, :round_robin, :weighted_shuffle, :lowest_cost],
       do: strategy

  defp routing_strategy("shuffle"), do: :shuffle
  defp routing_strategy("round_robin"), do: :round_robin
  defp routing_strategy("weighted_shuffle"), do: :weighted_shuffle
  defp routing_strategy("lowest_cost"), do: :lowest_cost
  defp routing_strategy(_strategy), do: :ordered
end
