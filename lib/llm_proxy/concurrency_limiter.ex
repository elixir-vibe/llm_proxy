defmodule LLMProxy.ConcurrencyLimiter do
  @moduledoc """
  In-memory concurrent-request admission for LLMProxy API keys.

  Add `LLMProxy.Limit.concurrent_requests/1` to a key's `budget_limits` to
  enable the gate. Admission and release do not query storage. Limits apply to
  one LLMProxy runtime instance; deployments with multiple instances must size
  each instance accordingly.

  A lease follows a stream into the process that consumes it. The lease is
  released when the request or stream ends, when stream enumeration halts, or
  when the process that owns the lease exits.
  """

  alias LLMProxy.ConcurrencyLimiter.{Lease, Server}

  defmodule Lease do
    @moduledoc false

    @enforce_keys [:ref, :key_id, :limit]
    defstruct [:ref, :key_id, :limit]

    @type t :: %__MODULE__{
            ref: reference(),
            key_id: String.t(),
            limit: non_neg_integer()
          }
  end

  defmodule LeaseExpiredError do
    @moduledoc false
    defexception message: "Concurrent request lease is no longer active"
  end

  @type lease :: Lease.t() | :unlimited
  @type status :: %{
          active: non_neg_integer(),
          admitted: non_neg_integer(),
          rejected: non_neg_integer(),
          released: non_neg_integer()
        }

  @error_message "Concurrent request limit exceeded"
  @retry_after_seconds 1

  @doc "Returns the stable public message for an admission refusal."
  @spec error_message() :: String.t()
  def error_message, do: @error_message

  @doc "Returns the retry delay advertised by HTTP admission refusals."
  @spec retry_after_seconds() :: pos_integer()
  def retry_after_seconds, do: @retry_after_seconds

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: Supervisor.child_spec({Server, opts}, id: __MODULE__)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Server.start_link(opts)

  @doc """
  Tries to acquire one request lease for an API key.

  Keys without a concurrent-request limit receive an unlimited no-op lease.
  """
  @spec acquire(map(), pid()) ::
          {:ok, lease()} | {:error, {:limit_exceeded, non_neg_integer()}}
  def acquire(api_key, owner \\ self())

  def acquire(%{id: key_id} = api_key, owner) when is_pid(owner) do
    case LLMProxy.Limit.concurrent_request_limit(api_key) do
      nil -> {:ok, :unlimited}
      limit -> Server.acquire(to_string(key_id), limit, owner)
    end
  end

  @doc "Runs a non-streaming request while holding its configured lease."
  @spec run(map(), (-> result)) ::
          result | {:error, {:limit_exceeded, non_neg_integer()}}
        when result: term()
  def run(api_key, fun) when is_function(fun, 0) do
    case acquire(api_key) do
      {:ok, lease} ->
        try do
          fun.()
        after
          release(lease)
        end

      {:error, {:limit_exceeded, _limit}} = error ->
        error
    end
  end

  @doc "Releases a request lease. Repeated release calls are safe."
  @spec release(lease()) :: :ok
  def release(:unlimited), do: :ok
  def release(%Lease{} = lease), do: Server.release(lease)

  @doc """
  Wraps a stream so its lease follows the consumer and is always released.
  """
  @spec wrap_stream(Enumerable.t(), lease()) :: Enumerable.t()
  def wrap_stream(stream, :unlimited), do: stream

  def wrap_stream(stream, %Lease{} = lease) do
    Stream.transform(
      stream,
      fn -> transfer!(lease) end,
      fn item, active_lease -> {[item], active_lease} end,
      fn active_lease -> {[], active_lease} end,
      &release/1
    )
  end

  @doc "Returns aggregate content-free counters for limited requests."
  @spec status() :: status()
  def status, do: Server.status()

  @doc "Returns the current active count and configured limit for one key."
  @spec status(map() | String.t()) :: map()
  def status(%{id: key_id} = api_key) do
    key_id
    |> to_string()
    |> Server.status()
    |> Map.put(:limit, LLMProxy.Limit.concurrent_request_limit(api_key))
  end

  def status(key_id) when is_binary(key_id), do: Server.status(key_id)

  defp transfer!(lease) do
    case Server.transfer(lease, self()) do
      :ok -> lease
      {:error, :released} -> raise LeaseExpiredError
    end
  end
end
