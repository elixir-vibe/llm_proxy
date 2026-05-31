defmodule LLMProxy.ProviderRouting.WeightedShuffle do
  @moduledoc false

  @spec order([term()]) :: [term()]
  def order(deployments) do
    deployments
    |> Enum.group_by(& &1.order)
    |> Enum.sort_by(fn {order, _deployments} -> order end)
    |> Enum.flat_map(fn {_order, deployments} -> weighted_shuffle(deployments) end)
  end

  defp weighted_shuffle(deployments) do
    deployments
    |> Enum.map(fn deployment -> {deployment, priority(deployment)} end)
    |> Enum.sort_by(fn {_deployment, priority} -> priority end, :desc)
    |> Enum.map(fn {deployment, _priority} -> deployment end)
  end

  defp priority(%{weight: weight}) when is_integer(weight) and weight > 0 do
    :math.pow(:rand.uniform(), 1 / weight)
  end

  defp priority(_deployment), do: :rand.uniform()
end
