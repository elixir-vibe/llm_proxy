defmodule LLMProxy.ReleaseTasksTest do
  use ExUnit.Case, async: false

  alias LLMProxy.ReleaseTasks
  alias LLMProxy.RPC.AdminServer

  setup do
    previous = Application.get_env(:llm_proxy, :rpc_socket)

    on_exit(fn ->
      if previous do
        Application.put_env(:llm_proxy, :rpc_socket, previous)
      else
        Application.delete_env(:llm_proxy, :rpc_socket)
      end

      LLMProxy.Drain.cancel()
    end)

    :ok
  end

  test "drain release tasks call the running service over the existing RPC socket" do
    socket =
      Path.join(
        System.tmp_dir!(),
        "llm-proxy-release-drain-#{System.unique_integer([:positive])}.sock"
      )

    Application.put_env(:llm_proxy, :rpc_socket, socket)

    {:ok, server} = AdminServer.start_link(socket: socket)

    assert :ok = ReleaseTasks.drain_start()
    assert %{draining: true} = LLMProxy.Drain.status()
    assert :ok = ReleaseTasks.drain_await(100)
    assert :ok = ReleaseTasks.drain_cancel()
    assert %{draining: false} = LLMProxy.Drain.status()

    GenServer.stop(server)
  end

  test "drain await release task raises on timeout" do
    socket =
      Path.join(
        System.tmp_dir!(),
        "llm-proxy-release-drain-timeout-#{System.unique_integer([:positive])}.sock"
      )

    Application.put_env(:llm_proxy, :rpc_socket, socket)

    {:ok, server} = AdminServer.start_link(socket: socket)
    {:ok, ref} = LLMProxy.Drain.enter(:agent, %{})

    assert_raise RuntimeError, "LLMProxy drain timed out after 10ms", fn ->
      ReleaseTasks.drain_await(10)
    end

    assert :ok = LLMProxy.Drain.leave(ref)
    assert :ok = ReleaseTasks.drain_await(100)

    GenServer.stop(server)
  end

  test "Codex login release task starts Req Finch before token exchange" do
    Application.stop(:req)
    Application.stop(:finch)

    assert :ok = ReleaseTasks.ensure_http_client_started()
    assert Process.whereis(Req.Finch)
  after
    ReleaseTasks.ensure_http_client_started()
  end
end
