defmodule LLMProxy.Ops do
  @moduledoc """
  Local operational RPC surface for deployment lifecycle control.

  This is intentionally separate from the Incant/admin surface. It is intended
  for local deploy tooling over SafeRPC, not for public HTTP traffic.
  """

  use SafeRPC,
    service: :llm_proxy_ops,
    version: "1",
    atoms: [:active, :agents, :draining, :ready, :requests, :serving, :streams, :total]

  @doc false
  @spec client_atoms() :: [String.t()]
  def client_atoms, do: ~w(active agents draining ready requests serving streams total)

  @rpc true
  @doc "Start draining: reject new work while existing work finishes."
  @spec drain_start(map(), map(), term()) :: {:ok, map()}
  def drain_start(_payload, _meta, _state) do
    {:ok, LLMProxy.Drain.start()}
  end

  @rpc true
  @doc "Cancel drain mode and accept new work again."
  @spec drain_cancel(map(), map(), term()) :: {:ok, map()}
  def drain_cancel(_payload, _meta, _state) do
    {:ok, LLMProxy.Drain.cancel()}
  end

  @rpc true
  @doc "Return current drain status."
  @spec drain_status(map(), map(), term()) :: {:ok, map()}
  def drain_status(_payload, _meta, _state) do
    {:ok, LLMProxy.Drain.status()}
  end

  @rpc true
  @doc "Wait until active work reaches zero."
  @spec drain_await(map(), map(), term()) :: :ok | {:error, :timeout}
  def drain_await(payload, _meta, _state) do
    timeout = Map.get(payload, :timeout_ms, Map.get(payload, "timeout_ms", 30_000))
    LLMProxy.Drain.await_empty(timeout)
  end
end
