defmodule LLMProxy.Drain do
  @moduledoc """
  Runtime drain control for deployment-safe LLMProxy shutdowns.

  Drain mode is an operational state: new user work is rejected while existing
  work is allowed to finish. Control is exposed through local RPC/release tasks,
  not through public HTTP routes.
  """

  alias LLMProxy.Drain.Server

  @type ref :: reference()
  @type work_kind :: :request | :stream | :agent
  @type status :: %{
          draining: boolean(),
          ready: boolean(),
          serving: boolean(),
          active: %{
            total: non_neg_integer(),
            requests: non_neg_integer(),
            streams: non_neg_integer(),
            agents: non_neg_integer()
          }
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Server.start_link(opts)

  @spec start(keyword()) :: status()
  def start(opts \\ []), do: Server.start(opts)

  @spec cancel() :: status()
  def cancel, do: Server.cancel()

  @spec status() :: status()
  def status, do: Server.status()

  @spec draining?() :: boolean()
  def draining?, do: status().draining

  @spec enter(work_kind(), map()) :: {:ok, ref()} | {:error, :draining}
  def enter(kind \\ :request, meta \\ %{}), do: Server.enter(kind, meta)

  @spec leave(ref()) :: :ok
  def leave(ref), do: Server.leave(ref)

  @spec track(work_kind(), map(), (-> result)) :: result | {:error, :draining} when result: term()
  def track(kind \\ :request, meta \\ %{}, fun) when is_function(fun, 0) do
    case enter(kind, meta) do
      {:ok, ref} ->
        try do
          fun.()
        after
          leave(ref)
        end

      {:error, :draining} ->
        {:error, :draining}
    end
  end

  @spec await_empty(timeout()) :: :ok | {:error, :timeout}
  def await_empty(timeout \\ 30_000), do: Server.await_empty(timeout)
end
