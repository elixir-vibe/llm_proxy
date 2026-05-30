defmodule LLMProxy.Routing.Shuffle do
  @moduledoc false

  @spec order([term()]) :: [term()]
  def order(deployments) do
    deployments
    |> Enum.group_by(& &1.order)
    |> Enum.sort_by(fn {order, _deployments} -> order end)
    |> Enum.flat_map(fn {_order, deployments} -> Enum.shuffle(deployments) end)
  end
end
