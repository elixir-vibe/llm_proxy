defmodule LLMProxy.ConcurrencyLimiter.Server do
  @moduledoc false

  use GenServer

  alias LLMProxy.ConcurrencyLimiter.Lease

  defstruct leases: %{},
            monitors: %{},
            active_by_key: %{},
            admitted: 0,
            rejected: 0,
            released: 0

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec acquire(String.t(), non_neg_integer(), pid()) ::
          {:ok, Lease.t()} | {:error, {:limit_exceeded, non_neg_integer()}}
  def acquire(key_id, limit, owner) do
    GenServer.call(__MODULE__, {:acquire, key_id, limit, owner})
  end

  @spec release(Lease.t()) :: :ok
  def release(%Lease{ref: ref}), do: GenServer.call(__MODULE__, {:release, ref})

  @spec transfer(Lease.t(), pid()) :: :ok | {:error, :released}
  def transfer(%Lease{ref: ref}, owner) do
    GenServer.call(__MODULE__, {:transfer, ref, owner})
  end

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec status(String.t()) :: map()
  def status(key_id), do: GenServer.call(__MODULE__, {:status, key_id})

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_call({:acquire, key_id, limit, owner}, _from, state) do
    active = Map.get(state.active_by_key, key_id, 0)

    if active >= limit do
      {:reply, {:error, {:limit_exceeded, limit}}, %{state | rejected: state.rejected + 1}}
    else
      ref = make_ref()
      monitor = Process.monitor(owner)

      lease = %Lease{ref: ref, key_id: key_id, limit: limit}
      lease_state = %{key_id: key_id, owner: owner, monitor: monitor}

      state = %{
        state
        | leases: Map.put(state.leases, ref, lease_state),
          monitors: Map.put(state.monitors, monitor, ref),
          active_by_key: Map.put(state.active_by_key, key_id, active + 1),
          admitted: state.admitted + 1
      }

      {:reply, {:ok, lease}, state}
    end
  end

  def handle_call({:release, ref}, _from, state) do
    {:reply, :ok, remove_lease(state, ref, true)}
  end

  def handle_call({:transfer, ref, owner}, _from, state) do
    case Map.fetch(state.leases, ref) do
      {:ok, %{owner: ^owner}} ->
        {:reply, :ok, state}

      {:ok, lease_state} ->
        Process.demonitor(lease_state.monitor, [:flush])
        monitor = Process.monitor(owner)

        state = %{
          state
          | leases: Map.put(state.leases, ref, %{lease_state | owner: owner, monitor: monitor}),
            monitors:
              state.monitors
              |> Map.delete(lease_state.monitor)
              |> Map.put(monitor, ref)
        }

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :released}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       active: map_size(state.leases),
       admitted: state.admitted,
       rejected: state.rejected,
       released: state.released
     }, state}
  end

  def handle_call({:status, key_id}, _from, state) do
    {:reply, %{key_id: key_id, active: Map.get(state.active_by_key, key_id, 0)}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, ref} -> {:noreply, remove_lease(state, ref, false)}
      :error -> {:noreply, state}
    end
  end

  defp remove_lease(state, ref, demonitor?) do
    case Map.pop(state.leases, ref) do
      {nil, _leases} ->
        state

      {lease, leases} ->
        if demonitor?, do: Process.demonitor(lease.monitor, [:flush])

        %{
          state
          | leases: leases,
            monitors: Map.delete(state.monitors, lease.monitor),
            active_by_key: decrement_active(state.active_by_key, lease.key_id),
            released: state.released + 1
        }
    end
  end

  defp decrement_active(active_by_key, key_id) do
    case Map.get(active_by_key, key_id, 0) do
      count when count <= 1 -> Map.delete(active_by_key, key_id)
      count -> Map.put(active_by_key, key_id, count - 1)
    end
  end
end
