defmodule LLMProxy.SafeRPCTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.RPC.AdminServer

  setup do
    LLMProxy.Catalog.load([
      Model.new!(
        name: "rpc-test-model",
        deployments: [Deployment.new!(provider: __MODULE__, upstream_model: "upstream")]
      )
    ])

    :ok
  end

  test "declares LLMProxy service operations" do
    descriptor = LLMProxy.__safe_rpc_descriptor__()

    assert %SafeRPC.Descriptor{service: :llm_proxy, version: "1", module: LLMProxy} = descriptor
    assert %{ops: ops} = Map.fetch!(descriptor.modules, LLMProxy)
    assert %{models: models, chat: chat, status: status} = ops
    assert models.docs == "List available models."
    assert models.spec != nil
    assert chat.docs == "Run a chat completion through LLMProxy."
    assert status.docs == "Return service status."
  end

  test "declares Incant service operations" do
    descriptor = LLMProxy.Admin.__safe_rpc_descriptor__()
    atoms = LLMProxy.Admin.__safe_rpc_atoms__()

    assert %SafeRPC.Descriptor{service: :llm_proxy, version: "1", module: LLMProxy.Admin} =
             descriptor

    assert %{ops: ops} = Map.fetch!(descriptor.modules, LLMProxy.Admin)

    assert %{
             describe: describe,
             index: index,
             read: read,
             run_action: run_action,
             run_widget: run_widget
           } = ops

    assert describe.docs == "Describe this Incant admin surface."
    assert index.spec != nil
    assert read.spec != nil
    assert run_action.spec != nil
    assert run_widget.spec != nil

    for atom <- ["compact", "density", "options", "select", "safe_rpc_reply"] do
      assert atom in atoms
    end
  end

  test "runs LLMProxy model and status operations" do
    assert {:ok, [%{id: "rpc-test-model", object: "model"}]} =
             LLMProxy.call({LLMProxy, :models}, %{}, %{}, [])

    assert {:ok, %{service: :llm_proxy, version: version, models: 1}} =
             LLMProxy.call({LLMProxy, :status}, %{}, %{}, [])

    assert is_binary(version)
  end

  test "real RPC server exposes admin and operations on one socket" do
    LLMProxy.Drain.cancel()
    socket = socket_path("composite")
    {:ok, server} = AdminServer.start_link(socket: socket)

    assert {:ok, %SafeRPC.Descriptor{modules: modules}} = SafeRPC.describe(socket)
    assert Map.has_key?(modules, LLMProxy.Admin)
    assert Map.has_key?(modules, LLMProxy.Ops)

    assert {:ok, %{draining: false}} = SafeRPC.call(socket, {LLMProxy.Ops, :drain_status})
    assert {:ok, %{draining: true}} = SafeRPC.call(socket, {LLMProxy.Ops, :drain_start})
    assert {:ok, %{draining: false}} = SafeRPC.call(socket, {LLMProxy.Ops, :drain_cancel})

    GenServer.stop(server)
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "llm-proxy-safe-rpc-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
