defmodule LLMProxy.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias LLMProxy.Router

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
    %{"object" => "list", "data" => data} = Jason.decode!(conn.resp_body)
    assert is_list(data)
  end

  test "accepts image-bearing JSON bodies above Plug's default limit" do
    body = Jason.encode!(%{"image" => String.duplicate("x", 8_100_000)})

    conn =
      conn(:post, "/nonexistent", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 404
  end

  test "unknown route returns 404" do
    conn =
      conn(:get, "/nonexistent")
      |> Router.call(@opts)

    assert conn.status == 404
  end
end
