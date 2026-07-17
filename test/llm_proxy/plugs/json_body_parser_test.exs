defmodule LLMProxy.Plugs.JSONBodyParserTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias LLMProxy.Plugs.JSONBodyParser

  test "uses the bounded request size supported by image-bearing LLM APIs" do
    assert JSONBodyParser.body_limit_bytes() == 32_000_000
  end

  test "returns a structured 413 response when the body exceeds the limit" do
    opts = JSONBodyParser.init(length: 100)

    conn =
      conn(:post, "/", Jason.encode!(%{"data" => String.duplicate("x", 101)}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> JSONBodyParser.call(opts)

    assert conn.halted
    assert conn.status == 413

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "request_too_large",
               "message" => "Request body exceeds the 100 bytes limit"
             }
           }
  end
end
