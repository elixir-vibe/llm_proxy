defmodule LLMProxy.Providers.Routing.RoundRobin do
  @moduledoc """
  GenServer-backed routing strategy that rotates deployments within each order group by model name.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @spec order(String.t(), [term()]) :: [term()]
  def order(name, deployments) when is_binary(name) do
    GenServer.call(__MODULE__, {:order, name, deployments})
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:order, name, deployments}, _from, offsets) do
    ordered_groups = deployments |> Enum.group_by(& &1.order) |> Enum.sort_by(&elem(&1, 0))
    offset = Map.get(offsets, name, 0)
    routed = Enum.flat_map(ordered_groups, fn {_order, group} -> rotate(group, offset) end)
    {:reply, routed, Map.put(offsets, name, offset + 1)}
  end

  def handle_call(:reset, _from, _offsets), do: {:reply, :ok, %{}}

  defp rotate([], _offset), do: []

  defp rotate(items, offset) do
    count = length(items)
    {left, right} = Enum.split(items, rem(offset, count))
    right ++ left
  end
end
