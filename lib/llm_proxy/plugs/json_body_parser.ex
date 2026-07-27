defmodule LLMProxy.Plugs.JSONBodyParser do
  @moduledoc """
  Parses authenticated JSON request bodies with a bounded limit and a structured oversized response.

  Keep this plug after authentication and quota checks so rejected clients cannot make the proxy
  read or decode large JSON bodies.
  """

  @behaviour Plug

  import Plug.Conn

  alias LLMProxy.Config
  alias LLMProxy.HTTP.ErrorResponse

  @spec body_limit_bytes() :: pos_integer()
  def body_limit_bytes, do: Config.body_limit_bytes()

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    limit = Keyword.get_lazy(opts, :length, &body_limit_bytes/0)

    if declared_length_exceeds?(conn, limit) do
      send_too_large(conn, limit)
    else
      parse_body(conn, limit)
    end
  end

  defp parse_body(conn, limit) do
    parser_opts =
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: limit
      )

    Plug.Parsers.call(conn, parser_opts)
  rescue
    Plug.Parsers.RequestTooLargeError -> send_too_large(conn, limit)
    Plug.Parsers.ParseError -> send_invalid_json(conn)
  end

  defp declared_length_exceeds?(conn, limit) do
    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {bytes, ""} -> bytes > limit
          _other -> false
        end

      _other ->
        false
    end
  end

  defp send_too_large(conn, limit) do
    conn
    |> ErrorResponse.send(
      413,
      "request_too_large",
      "Request body exceeds the #{format_limit(limit)} limit"
    )
    |> halt()
  end

  defp send_invalid_json(conn) do
    conn
    |> ErrorResponse.send(400, "invalid_json", "Request body is not valid JSON")
    |> halt()
  end

  defp format_limit(bytes) when bytes >= 1_000_000 and rem(bytes, 1_000_000) == 0,
    do: "#{div(bytes, 1_000_000)} MB"

  defp format_limit(bytes), do: "#{bytes} bytes"
end
