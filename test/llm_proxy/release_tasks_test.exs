defmodule LLMProxy.ReleaseTasksTest do
  use ExUnit.Case, async: false

  alias LLMProxy.ReleaseTasks
  alias LLMProxy.RPC.AdminServer

  defmodule SecretErrorCodec do
    @behaviour LLMProxy.Provider.TokenCodec

    @impl true
    def validate_options(_options), do: {:error, {:secret, "seeded-secret"}}

    @impl true
    def encode(value, _context, _options), do: {:ok, value}

    @impl true
    def decode(value, _context, _options), do: {:ok, value}

    @impl true
    def encoded?(_value, _options), do: false
  end

  setup do
    previous = Application.get_env(:llm_proxy, :rpc_socket)
    previous_env = System.get_env("LLM_PROXY_RPC_SOCKET")
    previous_codec = Application.fetch_env(:llm_proxy, :provider_token_codec)

    on_exit(fn ->
      if previous do
        Application.put_env(:llm_proxy, :rpc_socket, previous)
      else
        Application.delete_env(:llm_proxy, :rpc_socket)
      end

      if previous_env do
        System.put_env("LLM_PROXY_RPC_SOCKET", previous_env)
      else
        System.delete_env("LLM_PROXY_RPC_SOCKET")
      end

      case previous_codec do
        {:ok, codec} -> Application.put_env(:llm_proxy, :provider_token_codec, codec)
        :error -> Application.delete_env(:llm_proxy, :provider_token_codec)
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

  test "release tasks use the RPC socket environment in a clean eval-style VM" do
    socket =
      Path.join(
        System.tmp_dir!(),
        "llm-proxy-release-drain-env-#{System.unique_integer([:positive])}.sock"
      )

    Application.delete_env(:llm_proxy, :rpc_socket)
    System.put_env("LLM_PROXY_RPC_SOCKET", socket)
    {:ok, server} = AdminServer.start_link(socket: socket)

    assert :ok = ReleaseTasks.drain_status()

    GenServer.stop(server)
  end

  test "deployment drain restores service when active work does not finish" do
    socket =
      Path.join(
        System.tmp_dir!(),
        "llm-proxy-release-deploy-drain-#{System.unique_integer([:positive])}.sock"
      )

    Application.put_env(:llm_proxy, :rpc_socket, socket)
    {:ok, server} = AdminServer.start_link(socket: socket)
    {:ok, ref} = LLMProxy.Drain.enter(:stream, %{})

    assert_raise RuntimeError, "LLMProxy drain timed out after 10ms", fn ->
      ReleaseTasks.drain_for_deploy(10)
    end

    assert %{draining: false, active: %{streams: 1}} = LLMProxy.Drain.status()
    assert :ok = LLMProxy.Drain.leave(ref)

    GenServer.stop(server)
  end

  test "deployment drain remains active after work reaches zero" do
    socket =
      Path.join(
        System.tmp_dir!(),
        "llm-proxy-release-deploy-empty-#{System.unique_integer([:positive])}.sock"
      )

    Application.put_env(:llm_proxy, :rpc_socket, socket)
    {:ok, server} = AdminServer.start_link(socket: socket)

    assert :ok = ReleaseTasks.drain_for_deploy(100)
    assert %{draining: true, active: %{total: 0}} = LLMProxy.Drain.status()
    assert :ok = ReleaseTasks.drain_cancel()

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

  test "provider-token operation failures do not print custom codec reasons" do
    Application.put_env(:llm_proxy, :provider_token_codec, SecretErrorCodec)

    error =
      assert_raise RuntimeError, "provider token operation failed", fn ->
        ReleaseTasks.provider_tokens_status()
      end

    refute Exception.message(error) =~ "seeded-secret"
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
