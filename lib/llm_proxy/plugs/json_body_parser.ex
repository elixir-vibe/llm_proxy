defmodule LLMProxy.Plugs.JSONBodyParser do
  @moduledoc """
  Parses authenticated JSON request bodies with a bounded limit and a structured oversized response.

  Keep this plug after authentication and quota checks so rejected clients cannot make the proxy
  read or decode large JSON bodies.
  """

  @behaviour Plug

  import Plug.Conn

  alias LLMProxy.HTTP

  @max_body_bytes 32_000_000

  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @impl Plug
  def init(opts) do
    max_body_bytes = Keyword.get(opts, :length, @max_body_bytes)

    parser_opts =
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: max_body_bytes
      )

    %{max_body_bytes: max_body_bytes, parser_opts: parser_opts}
  end

  @impl Plug
  def call(conn, %{max_body_bytes: max_body_bytes, parser_opts: parser_opts}) do
    Plug.Parsers.call(conn, parser_opts)
  rescue
    Plug.Parsers.RequestTooLargeError ->
      conn
      |> HTTP.send_json(413, %{
        error: %{
          code: "request_too_large",
          message: "Request body exceeds the #{format_limit(max_body_bytes)} limit"
        }
      })
      |> halt()
  end

  defp format_limit(bytes) when bytes >= 1_000_000 and rem(bytes, 1_000_000) == 0,
    do: "#{div(bytes, 1_000_000)} MB"

  defp format_limit(bytes), do: "#{bytes} bytes"
end
