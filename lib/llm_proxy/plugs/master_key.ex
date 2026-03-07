defmodule LLMProxy.Plugs.MasterKey do
  @moduledoc """
  Requires master key for admin endpoints.
  """

  import Plug.Conn

  alias LLMProxy.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    key =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> k] -> k
        _ -> nil
      end

    if key == Config.master_key() do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
      |> halt()
    end
  end
end
