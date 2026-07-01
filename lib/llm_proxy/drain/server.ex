defmodule LLMProxy.Drain.Server do
  @moduledoc false

  use GenServer

  @type work_kind :: :request | :stream | :agent

  defstruct draining: false,
            active: %{},
            waiters: %{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec start(keyword()) :: map()
  def start(opts \\ []), do: GenServer.call(__MODULE__, {:start, opts})

  @spec cancel() :: map()
  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec enter(work_kind(), map()) :: {:ok, reference()} | {:error, :draining}
  def enter(kind, meta \\ %{}), do: GenServer.call(__MODULE__, {:enter, kind, meta})

  @spec leave(reference()) :: :ok
  def leave(ref), do: GenServer.call(__MODULE__, {:leave, ref})

  @spec await_empty(timeout()) :: :ok | {:error, :timeout}
  def await_empty(timeout \\ 30_000)
  def await_empty(:infinity), do: GenServer.call(__MODULE__, {:await_empty, :infinity}, :infinity)

  def await_empty(timeout) when is_integer(timeout) and timeout >= 0 do
    GenServer.call(__MODULE__, {:await_empty, timeout}, timeout + 1_000)
  end

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_call({:start, _opts}, _from, state) do
    state = %{state | draining: true}
    {:reply, status(state), maybe_reply_waiters(state)}
  end

  def handle_call(:cancel, _from, state) do
    state = %{state | draining: false}
    {:reply, status(state), state}
  end

  def handle_call(:status, _from, state), do: {:reply, status(state), state}

  def handle_call({:enter, _kind, _meta}, _from, %{draining: true} = state) do
    {:reply, {:error, :draining}, state}
  end

  def handle_call({:enter, kind, meta}, _from, state) do
    ref = make_ref()

    active =
      Map.put(state.active, ref, %{
        kind: normalize_kind(kind),
        meta: meta,
        started_at: System.monotonic_time(:millisecond)
      })

    {:reply, {:ok, ref}, %{state | active: active}}
  end

  def handle_call({:leave, ref}, _from, state) do
    state = %{state | active: Map.delete(state.active, ref)}
    {:reply, :ok, maybe_reply_waiters(state)}
  end

  def handle_call({:await_empty, timeout}, from, state) do
    if map_size(state.active) == 0 do
      {:reply, :ok, state}
    else
      ref = make_ref()
      timer = await_timer(ref, timeout)
      {:noreply, %{state | waiters: Map.put(state.waiters, ref, {from, timer})}}
    end
  end

  @impl true
  def handle_info({:await_empty_timeout, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}

      {nil, _waiters} ->
        {:noreply, state}
    end
  end

  defp maybe_reply_waiters(%{active: active, waiters: waiters} = state)
       when map_size(active) == 0 and map_size(waiters) > 0 do
    Enum.each(waiters, fn {_ref, {from, timer}} ->
      cancel_timer(timer)
      GenServer.reply(from, :ok)
    end)

    %{state | waiters: %{}}
  end

  defp maybe_reply_waiters(state), do: state

  defp await_timer(_ref, :infinity), do: nil

  defp await_timer(ref, timeout),
    do: Process.send_after(self(), {:await_empty_timeout, ref}, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp status(state) do
    active = active_counts(state.active)

    %{
      draining: state.draining,
      ready: not state.draining,
      serving: active.total > 0,
      active: active
    }
  end

  defp active_counts(active) do
    counts =
      active
      |> Map.values()
      |> Enum.frequencies_by(& &1.kind)

    %{
      total: map_size(active),
      requests: Map.get(counts, :request, 0),
      streams: Map.get(counts, :stream, 0),
      agents: Map.get(counts, :agent, 0)
    }
  end

  defp normalize_kind(kind) when kind in [:request, :stream, :agent], do: kind
  defp normalize_kind(_kind), do: :request
end
