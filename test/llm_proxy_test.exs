defmodule LlmProxy.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias LlmProxy.Router

  @opts Router.init([])

  test "GET /health returns ok" do
    conn =
      conn(:get, "/health")
      |> Router.call(@opts)

    assert conn.status == 200
    assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
  end

  test "GET /v1/models returns list" do
    conn =
      conn(:get, "/v1/models")
      |> Router.call(@opts)

    assert conn.status == 200
    assert %{"object" => "list", "data" => []} = Jason.decode!(conn.resp_body)
  end

  test "unknown route returns 404" do
    conn =
      conn(:get, "/nonexistent")
      |> Router.call(@opts)

    assert conn.status == 404
  end
end
