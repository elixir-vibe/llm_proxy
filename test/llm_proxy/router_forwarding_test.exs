defmodule LLMProxy.RouterForwardingTest do
  use ExUnit.Case

  alias LLMProxy.Router
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  @opts Router.init([])

  setup do
    TestSupport.checkout_repo()
    Application.put_env(:llm_proxy, :master_key, "master-key")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)
  end

  test "forwards model aliases and keeps setup routes out of the core router" do
    setup_conn = Plug.Test.conn(:get, "/setup/models") |> Router.call(@opts)
    models_conn = Plug.Test.conn(:get, "/models") |> Router.call(@opts)

    assert setup_conn.status == 404
    assert models_conn.status == 200
    assert Jason.decode!(models_conn.resp_body)["object"] == "list"
  end

  test "forwards token routes and enforces master-key auth" do
    unauthorized = Plug.Test.conn(:get, "/tokens") |> Router.call(@opts)

    authorized =
      Plug.Test.conn(:get, "/tokens")
      |> Plug.Conn.fetch_query_params()
      |> TestSupport.put_bearer("master-key")
      |> Router.call(@opts)

    assert unauthorized.status == 401
    assert authorized.status == 200
    assert is_list(Jason.decode!(authorized.resp_body))
  end

  test "forwards key self-service usage routes" do
    {:ok, _key, raw_key} = Storage.create_key("router-user")

    conn =
      Plug.Test.conn(:get, "/keys/usage")
      |> TestSupport.put_bearer(raw_key)
      |> Router.call(@opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["name"] == "router-user"
  end

  test "forwards stats admin alias" do
    conn =
      Plug.Test.conn(:get, "/admin")
      |> TestSupport.put_bearer("master-key")
      |> Router.call(@opts)

    assert conn.status == 200
    assert Map.has_key?(Jason.decode!(conn.resp_body), "total_keys")
  end

  test "forwards chat routes" do
    conn =
      TestSupport.json_conn(:post, "/v1/chat/completions", %{"model" => "missing"})
      |> TestSupport.put_bearer("missing")
      |> Router.call(@opts)

    assert conn.status == 401
  end

  test "forwards moderation aliases" do
    conn =
      TestSupport.json_conn(:post, "/moderations", %{"input" => "hello"})
      |> TestSupport.put_bearer("missing")
      |> Router.call(@opts)

    assert conn.status == 401
  end
end
