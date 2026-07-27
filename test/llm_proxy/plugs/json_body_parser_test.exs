defmodule LLMProxy.Plugs.JSONBodyParserTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias LLMProxy.Plugs.JSONBodyParser

  test "uses the bounded request size supported by image-bearing LLM APIs" do
    assert JSONBodyParser.body_limit_bytes() == 32_000_000
  end

  test "rejects a declared oversized body before reading it" do
    opts = JSONBodyParser.init(length: 100)

    conn =
      conn(:post, "/", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("content-length", "101")
      |> JSONBodyParser.call(opts)

    assert_too_large(conn)
  end

  test "returns a structured 413 response when a body without a declared length exceeds the limit" do
    opts = JSONBodyParser.init(length: 100)

    conn =
      conn(:post, "/", Jason.encode!(%{"data" => String.duplicate("x", 101)}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.delete_req_header("content-length")
      |> JSONBodyParser.call(opts)

    assert_too_large(conn)
  end

  test "returns a protocol-native error for malformed JSON" do
    conn =
      conn(:post, "/v1/messages", "{invalid-json")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> JSONBodyParser.call(JSONBodyParser.init([]))

    assert conn.halted
    assert conn.status == 400

    assert Jason.decode!(conn.resp_body) == %{
             "type" => "error",
             "error" => %{
               "type" => "invalid_json",
               "message" => "Request body is not valid JSON"
             }
           }
  end

  defp assert_too_large(conn) do
    assert conn.halted
    assert conn.status == 413

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "message" => "Request body exceeds the 100 bytes limit",
               "type" => "request_too_large",
               "code" => "request_too_large",
               "status" => 413
             }
           }
  end
end
