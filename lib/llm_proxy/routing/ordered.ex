defmodule LLMProxy.Routing.Ordered do
  @moduledoc false

  @spec order([term()]) :: [term()]
  def order(deployments) do
    Enum.sort_by(deployments, & &1.order)
  end
end
