defmodule LLMProxy.Plugs.JSONBodyParser do
  @moduledoc """
  Parses authenticated JSON request bodies with a bounded limit and a structured oversized response.

  Keep this plug after authentication and quota checks so rejected clients cannot make the proxy
  read or decode large JSON bodies.
  """

  @behaviour Plug

  import Plug.Conn

  alias LLMProxy.{Config, HTTP}

  @spec body_limit_bytes() :: pos_integer()
  def body_limit_bytes, do: Config.body_limit_bytes()

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    limit = Keyword.get_lazy(opts, :length, &body_limit_bytes/0)

    parser_opts =
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: limit
      )

    try do
      Plug.Parsers.call(conn, parser_opts)
    rescue
      Plug.Parsers.RequestTooLargeError ->
        conn
        |> HTTP.send_json(413, %{
          error: %{
            code: "request_too_large",
            message: "Request body exceeds the #{format_limit(limit)} limit"
          }
        })
        |> halt()
    end
  end

  defp format_limit(bytes) when bytes >= 1_000_000 and rem(bytes, 1_000_000) == 0,
    do: "#{div(bytes, 1_000_000)} MB"

  defp format_limit(bytes), do: "#{bytes} bytes"
end
