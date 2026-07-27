defmodule LLMProxy.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias LLMProxy.Router

  @opts Router.init([])

  test "Cowboy keeps active streaming responses alive" do
    protocol_options = :ranch.get_protocol_options(LLMProxy.HTTP.Router.HTTP)

    assert protocol_options.idle_timeout == LLMProxy.Config.provider_receive_timeout_ms()
    assert protocol_options.reset_idle_timeout_on_send == true
  end

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

  test "authenticates before parsing JSON request bodies" do
    conn =
      conn(:post, "/v1/chat/completions", "{invalid-json")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 401

    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) ==
             "Missing API key"
  end

  test "accepts authenticated image-bearing JSON bodies above Plug's default limit" do
    body = Jason.encode!(%{"image" => String.duplicate("x", 8_100_000)})

    conn =
      conn(:post, "/v1/chat/completions", body)
      |> Plug.Conn.put_req_header("authorization", "Bearer test-master-key")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 400
    assert get_in(Jason.decode!(conn.resp_body), ["error", "code"]) == "missing_messages"
  end

  test "unknown route returns 404" do
    conn =
      conn(:get, "/nonexistent")
      |> Router.call(@opts)

    assert conn.status == 404
  end
end
