defmodule LLMProxy.Plugs.Drain do
  @moduledoc """
  Rejects new user work while LLMProxy is draining.

  Active work is tracked by route handlers so long-running chunked/SSE streams
  remain active until their stream enumeration completes.
  """

  import Plug.Conn

  alias LLMProxy.HTTP

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/health"} = conn, _opts), do: conn

  def call(%Plug.Conn{} = conn, _opts) do
    if LLMProxy.Drain.draining?() do
      conn
      |> put_resp_header("retry-after", "30")
      |> HTTP.send_json(503, %{
        error: %{
          code: "draining",
          message: "LLMProxy is draining and not accepting new requests"
        }
      })
      |> halt()
    else
      conn
    end
  end
end
