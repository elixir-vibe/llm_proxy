defmodule LLMProxy.SafeRPCTest do
  use ExUnit.Case, async: true

  defmodule Server do
    use SafeRPC.Adapter.Server, service: LLMProxy
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

  test "describes API and control operations" do
    descriptor = LLMProxy.__safe_rpc_descriptor__()

    assert %SafeRPC.Descriptor{service: :llm_proxy, version: "1", module: LLMProxy} = descriptor
    assert [:api, :control] = descriptor.surfaces |> Map.keys() |> Enum.sort()
    assert %{models: models, chat: chat} = descriptor.surfaces.api.ops
    assert models.docs == "List available models."
    assert models.spec != nil
    assert chat.docs == "Run a chat completion through LLMProxy."
    assert %{status: status, incant_describe: incant_describe} = descriptor.surfaces.control.ops
    assert status.docs == "Return service status."
    assert incant_describe.docs == "Describe LLMProxy's Incant admin surface."
  end

  test "runs non-secret API and control operations directly" do
    assert {:ok, models} = LLMProxy.call(:models, %{}, %{}, [])
    assert [%{id: "rpc-test-model", object: "model"}] = models

    assert {:ok, %{service: :llm_proxy, version: version, models: 1}} =
             LLMProxy.call(:status, %{}, %{}, [])

    assert is_binary(version)

    assert {:ok, %Incant.Admin.Contract{service: :llm_proxy}} =
             LLMProxy.call(:incant_describe, %{}, %{}, [])
  end

  test "describes LLMProxy over a SafeRPC socket" do
    socket = socket_path("describe")
    {:ok, server} = Server.start_link(socket: socket)

    assert {:ok, %SafeRPC.Descriptor{service: :llm_proxy, surfaces: surfaces}} =
             SafeRPC.describe(socket)

    assert Map.has_key?(surfaces.api.ops, :models)
    assert Map.has_key?(surfaces.control.ops, :incant_describe)

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
