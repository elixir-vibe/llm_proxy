defmodule LLMProxy.Providers.CircuitBreaker do
  @moduledoc false

  use GenServer

  alias LLMProxy.Providers.Routing.Attempt
  alias LLMProxy.Telemetry

  defstruct state: :closed, failures: 0, opened_at: nil, cooldown_ms: nil

  @type state :: :closed | :open | :half_open
  @type t :: %__MODULE__{
          state: state(),
          failures: non_neg_integer(),
          opened_at: integer() | nil,
          cooldown_ms: non_neg_integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @spec available?(Attempt.t()) :: boolean()
  def available?(%Attempt{} = attempt), do: GenServer.call(__MODULE__, {:available?, attempt})

  @spec success(Attempt.t()) :: :ok
  def success(%Attempt{} = attempt), do: GenServer.cast(__MODULE__, {:success, attempt})

  @spec failure(Attempt.t(), non_neg_integer() | nil) :: :ok
  def failure(%Attempt{} = attempt, cooldown_ms \\ nil) do
    GenServer.cast(__MODULE__, {:failure, attempt, cooldown_ms})
  end

  @spec status(Attempt.t()) :: t()
  def status(%Attempt{} = attempt),
    do: GenServer.call(__MODULE__, {:status, Attempt.key(attempt)})

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:available?, attempt}, _from, breakers) do
    key = Attempt.key(attempt)
    breaker = Map.get(breakers, key, %__MODULE__{})

    case breaker.state do
      :open ->
        if cooldown_elapsed?(breaker, attempt) do
          breaker = %{breaker | state: :half_open}
          Telemetry.emit([:circuit, :half_open], attempt)
          {:reply, true, Map.put(breakers, key, breaker)}
        else
          Telemetry.emit([:circuit, :skip], attempt)
          {:reply, false, breakers}
        end

      _state ->
        {:reply, true, breakers}
    end
  end

  def handle_call({:status, key}, _from, breakers) do
    {:reply, Map.get(breakers, key, %__MODULE__{}), breakers}
  end

  def handle_call(:reset, _from, _breakers), do: {:reply, :ok, %{}}

  @impl GenServer
  def handle_cast({:success, attempt}, breakers) do
    key = Attempt.key(attempt)
    breaker = Map.get(breakers, key, %__MODULE__{})

    if breaker.state != :closed do
      Telemetry.emit([:circuit, :closed], attempt)
    end

    {:noreply, Map.put(breakers, key, %__MODULE__{})}
  end

  def handle_cast({:failure, attempt, cooldown_ms}, breakers) do
    key = Attempt.key(attempt)
    breaker = Map.get(breakers, key, %__MODULE__{})
    failures = breaker.failures + 1

    breaker =
      if failures >= attempt.failure_threshold do
        Telemetry.emit([:circuit, :open], attempt, %{failures: failures})

        %__MODULE__{
          state: :open,
          failures: failures,
          opened_at: now_ms(),
          cooldown_ms: cooldown_ms
        }
      else
        %{breaker | failures: failures}
      end

    {:noreply, Map.put(breakers, key, breaker)}
  end

  defp cooldown_elapsed?(
         %__MODULE__{opened_at: opened_at, cooldown_ms: breaker_cooldown},
         %Attempt{cooldown_ms: attempt_cooldown}
       )
       when is_integer(opened_at) do
    now_ms() - opened_at >= (breaker_cooldown || attempt_cooldown)
  end

  defp cooldown_elapsed?(_breaker, _attempt), do: true

  defp now_ms, do: System.monotonic_time(:millisecond)
end
