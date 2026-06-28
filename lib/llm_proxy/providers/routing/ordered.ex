defmodule LLMProxy.Providers.Routing.Ordered do
  @moduledoc """
  Routing strategy that preserves deployment order for deterministic fallback.
  """

  @spec order([term()]) :: [term()]
  def order(deployments) do
    Enum.sort_by(deployments, & &1.order)
  end
end
