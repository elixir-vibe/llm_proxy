defmodule LLMProxy.SafeRPCTest do
  use ExUnit.Case, async: true

  defmodule Server do
    use SafeRPC.Adapter.Server, service: LLMProxy
  end

  defmodule AdminServer do
    use SafeRPC.Adapter.Server, service: LLMProxy.Admin
  end

  setup do
    LLMProxy.Catalog.load([
      %{
        name: "rpc-test-model",
        deployments: [%{provider: __MODULE__, upstream_model: "upstream"}]
      }
    ])

    :ok
  end

  test "describes LLMProxy module operations" do
    descriptor = LLMProxy.__safe_rpc_descriptor__()

    assert %SafeRPC.Descriptor{service: :llm_proxy, version: "1", module: LLMProxy} = descriptor
    assert %{ops: ops} = Map.fetch!(descriptor.modules, LLMProxy)
    assert %{models: models, chat: chat, status: status} = ops
    assert models.docs == "List available models."
    assert models.spec != nil
    assert chat.docs == "Run a chat completion through LLMProxy."
    assert status.docs == "Return service status."
  end

  test "runs non-secret API and control operations directly" do
    assert {:ok, models} = LLMProxy.call(:models, %{}, %{}, [])
    assert [%{id: "rpc-test-model", object: "model"}] = models

    assert {:ok, %{service: :llm_proxy, version: version, models: 1}} =
             LLMProxy.call(:status, %{}, %{}, [])

    assert is_binary(version)
  end

  test "describes LLMProxy over a SafeRPC socket" do
    socket = socket_path("describe")
    {:ok, server} = Server.start_link(socket: socket)

    assert {:ok, %SafeRPC.Descriptor{service: :llm_proxy, modules: modules}} =
             SafeRPC.describe(socket)

    assert Map.has_key?(modules[LLMProxy].ops, :models)
    assert Map.has_key?(modules[LLMProxy].ops, :status)

    GenServer.stop(server)
  end

  test "LLMProxy.Admin exposes Incant service operations with rpc: true" do
    descriptor = LLMProxy.Admin.__safe_rpc_descriptor__()

    assert %SafeRPC.Descriptor{service: :llm_proxy, version: "1", module: LLMProxy.Admin} =
             descriptor

    assert %{ops: ops} = Map.fetch!(descriptor.modules, LLMProxy.Admin)

    assert %{incant_describe: describe, incant_index: index, incant_read: read} = ops

    assert describe.docs == "Describe this Incant admin surface."
    assert index.spec != nil
    assert read.spec != nil
  end

  test "calls LLMProxy.Admin Incant service over a SafeRPC socket" do
    socket = socket_path("admin")
    {:ok, server} = AdminServer.start_link(socket: socket)

    assert {:ok, %Incant.Admin.Contract{service: :llm_proxy}} =
             SafeRPC.call(socket, :incant_describe, %Incant.Service.Describe{})

    GenServer.stop(server)
  end

  test "calls LLMProxy operations over a SafeRPC socket" do
    socket = socket_path("models")
    {:ok, server} = Server.start_link(socket: socket)

    assert {:ok, [%{id: "rpc-test-model"}]} = SafeRPC.call(socket, :models)
    assert {:ok, %{service: :llm_proxy, models: 1}} = SafeRPC.call(socket, :status)

    GenServer.stop(server)
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "llm-proxy-safe-rpc-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
