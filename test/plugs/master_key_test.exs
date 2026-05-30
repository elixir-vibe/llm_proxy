defmodule LLMProxy.Plugs.MasterKeyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias LLMProxy.Plugs.MasterKey

  setup do
    Application.put_env(:llm_proxy, :master_key, "super-secret")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)
  end

  test "allows requests with the master key" do
    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Bearer super-secret")
      |> MasterKey.call([])

    refute conn.halted
  end

  test "halts unauthorized requests" do
    conn = conn(:get, "/") |> MasterKey.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end

  test "fails closed when the master key is not configured" do
    Application.delete_env(:llm_proxy, :master_key)

    conn = conn(:get, "/") |> MasterKey.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "fails closed when the configured master key is empty" do
    Application.put_env(:llm_proxy, :master_key, "")

    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Bearer ")
      |> MasterKey.call([])

    assert conn.halted
    assert conn.status == 401
  end
end
