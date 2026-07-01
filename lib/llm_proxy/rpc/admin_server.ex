defmodule LLMProxy.RPC.AdminServer do
  @moduledoc """
  SafeRPC socket server for LLMProxy local RPC surfaces.

  The same local socket serves the Incant admin surface (`LLMProxy.Admin`) and
  operational lifecycle surface (`LLMProxy.Ops`). The boundary is the SafeRPC
  operation module/function tuple, not a separate transport.
  """

  use SafeRPC.Server

  @services [LLMProxy.Admin, LLMProxy.Ops]

  @impl true
  def init(opts) do
    states =
      Map.new(@services, fn service ->
        {:ok, state} = service.init(opts)
        {service, state}
      end)

    {:ok, states}
  end

  @impl true
  def handle_call(:safe_rpc_describe, _payload, state) do
    {:reply, describe(state), state}
  end

  def handle_call(:safe_rpc_atoms, _payload, state) do
    {:reply, atoms(), state}
  end

  def handle_call(op, payload, state) do
    {:reply, dispatch(:call, op, payload, %{}, state), state}
  end

  @impl true
  def handle_request(%{kind: :call, op: :safe_rpc_describe}, state) do
    {:reply, describe(state), state}
  end

  def handle_request(%{kind: :call, op: :safe_rpc_atoms}, state) do
    {:reply, atoms(), state}
  end

  def handle_request(%{kind: :call, op: op, payload: payload, meta: meta}, state) do
    {:reply, dispatch(:call, op, payload, meta, state), state}
  end

  def handle_request(%{kind: :cast, op: op, payload: payload, meta: meta}, state) do
    _result = dispatch(:cast, op, payload, meta, state)
    {:reply, {:ok, :noreply}, state}
  end

  defp dispatch(_kind, {service, _function} = op, payload, meta, state) do
    if service in @services do
      service.call(op, payload, meta, Map.fetch!(state, service))
    else
      {:error, :unknown_operation}
    end
  end

  defp dispatch(_kind, _op, _payload, _meta, _state), do: {:error, :unknown_operation}

  defp describe(state) do
    descriptors =
      Enum.map(@services, fn service ->
        {:ok, descriptor} = SafeRPC.Adapter.Server.describe(service, Map.fetch!(state, service))
        descriptor
      end)

    {:ok, merge_descriptors(descriptors)}
  end

  defp atoms do
    atoms =
      @services
      |> Enum.flat_map(fn service ->
        {:ok, atoms} = SafeRPC.Adapter.Server.atoms(service, nil)
        atoms
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, atoms}
  end

  defp merge_descriptors([descriptor | rest]) do
    Enum.reduce(rest, descriptor, fn next, acc ->
      %{acc | modules: Map.merge(acc.modules, next.modules)}
    end)
  end
end
