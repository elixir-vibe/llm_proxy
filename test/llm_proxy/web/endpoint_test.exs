defmodule LLMProxy.Web.EndpointTest do
  use ExUnit.Case

  import Plug.Test

  alias LLMProxy.Web.Endpoint

  @opts Endpoint.init([])

  setup do
    Application.put_env(:llm_proxy, :master_key, "admin-secret")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)
  end

  test "routes admin requests to the Phoenix router" do
    conn = conn(:get, "/admin/login") |> Endpoint.call(@opts)

    assert conn.status == 200
    assert conn.resp_body =~ "LLM Proxy Admin"
  end

  test "routes api requests to the plug router" do
    conn = conn(:get, "/health") |> Endpoint.call(@opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok", "version" => "0.1.0"}
  end
end
