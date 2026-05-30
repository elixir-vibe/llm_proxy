defmodule LLMProxy.Stream.SSEWriterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias LLMProxy.Stream.SSEWriter

  test "starts and writes chunked SSE responses" do
    conn = SSEWriter.start_sse(conn(:get, "/"))

    assert conn.state == :chunked
    assert {:ok, conn} = SSEWriter.write_event(conn, %{"message" => "hello"})
    assert {:ok, conn} = SSEWriter.write_named_event(conn, "update", %{"step" => 1})
    assert {:ok, _conn} = SSEWriter.write_done(conn)
  end
end
