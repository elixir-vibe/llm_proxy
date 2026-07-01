defmodule LLMProxy.SafeRPCTest do
  use ExUnit.Case, async: true

  alias Incant.Service.{Entry, RegistryServer}
  alias LLMProxy.Catalog.{Deployment, Model}

  defmodule Server do
    use SafeRPC.Adapter.Server, service: LLMProxy
  end

  defmodule AdminServer do
    use SafeRPC.Adapter.Server, service: LLMProxy.Admin
  end

  setup do
    LLMProxy.Catalog.load([
      Model.new!(
        name: "rpc-test-model",
        deployments: [Deployment.new!(provider: __MODULE__, upstream_model: "upstream")]
      )
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
    assert {:ok, models} = LLMProxy.call({LLMProxy, :models}, %{}, %{}, [])
    assert [%{id: "rpc-test-model", object: "model"}] = models

    assert {:ok, %{service: :llm_proxy, version: version, models: 1}} =
             LLMProxy.call({LLMProxy, :status}, %{}, %{}, [])

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
    atoms = LLMProxy.Admin.__safe_rpc_atoms__()

    assert %SafeRPC.Descriptor{service: :llm_proxy, version: "1", module: LLMProxy.Admin} =
             descriptor

    assert %{ops: ops} = Map.fetch!(descriptor.modules, LLMProxy.Admin)

    assert %{describe: describe, index: index, read: read, run_action: run_action} = ops

    assert describe.docs == "Describe this Incant admin surface."
    assert index.spec != nil
    assert read.spec != nil
    assert run_action.spec != nil

    for atom <- ["compact", "density", "options", "select", "safe_rpc_reply"] do
      assert atom in atoms
    end
  end

  test "discovers and calls LLMProxy.Admin through the Incant service client" do
    socket = socket_path("admin")
    {:ok, server} = AdminServer.start_link(socket: socket)

    bindings = %{
      llm_proxy: %{
        socket: socket,
        modules: [LLMProxy, LLMProxy.Admin]
      }
    }

    assert {:ok, [%Incant.Service.Client{module: LLMProxy.Admin} = client]} =
             Incant.Service.discover(bindings)

    assert {:ok, %Incant.Admin.Contract{service: :llm_proxy}} =
             Incant.Service.describe(client)

    {:ok, registry} = RegistryServer.start_link(bindings: bindings)

    assert [%Entry{key: :llm_proxy, contract: contract}] =
             RegistryServer.list_entries(registry)

    assert %Incant.Admin.Contract{service: :llm_proxy} = contract

    session = Incant.Service.Session.new(List.first(RegistryServer.list_entries(registry)))
    assert [_resource | _] = Incant.Session.list_surfaces(session, kind: :resource)

    assert {:ok,
            %Incant.ActionResult.Job{
              id: "codex_oauth",
              meta: %{
                "oauth" => %{
                  "authorization_url" => authorization_url,
                  "state" => state,
                  "verifier" => verifier
                }
              }
            }} =
             Incant.Service.Session.run_action(
               session,
               "provider_token",
               "codex_oauth_start",
               %{}
             )

    assert authorization_url =~ "https://auth.openai.com/oauth/authorize"
    assert authorization_url =~ URI.encode_query(%{state: state})
    assert is_binary(verifier)

    GenServer.stop(registry)
    GenServer.stop(server)
  end

  test "calls LLMProxy operations over a SafeRPC socket" do
    socket = socket_path("models")
    {:ok, server} = Server.start_link(socket: socket)

    assert {:ok, [%{id: "rpc-test-model"}]} = SafeRPC.call(socket, {LLMProxy, :models})
    assert {:ok, %{service: :llm_proxy, models: 1}} = SafeRPC.call(socket, {LLMProxy, :status})

    GenServer.stop(server)
  end

  test "real LLMProxy RPC server dispatches admin and ops services on one socket" do
    LLMProxy.Drain.cancel()
    socket = socket_path("composite")
    {:ok, server} = LLMProxy.RPC.AdminServer.start_link(socket: socket)

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
