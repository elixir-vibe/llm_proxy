defmodule LLMProxy.Stream.SSEWriter do
  @moduledoc """
  Helpers for writing SSE events to a Plug.Conn chunked response.
  """

  import Plug.Conn

  def start_sse(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
  end

  def write_event(conn, data) when is_binary(data) do
    chunk(conn, "data: #{data}\n\n")
  end

  def write_event(conn, data) when is_map(data) do
    write_event(conn, Jason.encode!(data))
  end

  def write_named_event(conn, event_name, data) when is_binary(data) do
    chunk(conn, "event: #{event_name}\ndata: #{data}\n\n")
  end

  def write_named_event(conn, event_name, data) when is_map(data) do
    write_named_event(conn, event_name, Jason.encode!(data))
  end

  def write_done(conn) do
    chunk(conn, "data: [DONE]\n\n")
  end
end
