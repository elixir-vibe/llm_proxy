defmodule LLMProxy.Trace do
  @moduledoc false

  alias Plug.Conn

  @request_header "x-request-id"
  @proxy_header "x-llm-proxy-trace-id"

  @spec request_header() :: String.t()
  def request_header, do: @request_header

  @spec proxy_header() :: String.t()
  def proxy_header, do: @proxy_header

  @spec new_id() :: String.t()
  def new_id do
    binary = <<
      System.system_time(:nanosecond)::64,
      :erlang.phash2({node(), self()}, 16_777_216)::24,
      :erlang.unique_integer()::32
    >>

    Base.url_encode64(binary)
  end

  @spec ensure_conn(Conn.t()) :: {Conn.t(), String.t()}
  def ensure_conn(%Conn{} = conn) do
    request_id =
      conn.assigns[:request_id] || response_request_id(conn) || request_id(conn) || new_id()

    conn =
      conn
      |> Conn.put_resp_header(@request_header, request_id)
      |> Conn.put_resp_header(@proxy_header, request_id)

    {conn, request_id}
  end

  defp request_id(conn) do
    conn
    |> Conn.get_req_header(@request_header)
    |> List.first()
    |> valid_id()
  end

  defp response_request_id(conn) do
    conn
    |> Conn.get_resp_header(@request_header)
    |> List.first()
    |> valid_id()
  end

  defp valid_id(id) when is_binary(id) and byte_size(id) in 20..200, do: id
  defp valid_id(_id), do: nil
end
