defmodule LLMProxy.Providers.Routing.LowestCost do
  @moduledoc false

  alias LLMProxy.ModelDB

  @spec order([term()]) :: [term()]
  def order(deployments) do
    deployments
    |> Enum.group_by(& &1.order)
    |> Enum.sort_by(fn {order, _deployments} -> order end)
    |> Enum.flat_map(fn {_order, deployments} -> Enum.sort_by(deployments, &cost/1) end)
  end

  defp cost(%{provider: provider, upstream_model: model}) do
    case ModelDB.pricing(model, provider) do
      %{"input" => input, "output" => output} when is_number(input) and is_number(output) ->
        input + output

      _pricing ->
        :infinity
    end
  end
end
