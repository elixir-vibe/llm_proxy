defmodule LLMProxy.CacheBodyReaderTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias LLMProxy.CacheBodyReader

  test "caches the raw request body" do
    conn = conn(:post, "/", "hello world")

    assert {:ok, "hello world", conn} = CacheBodyReader.read_body(conn, [])
    assert conn.private.raw_body == "hello world"
  end
end
