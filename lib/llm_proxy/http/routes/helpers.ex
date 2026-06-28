defmodule LLMProxy.HTTP.Routes.Helpers do
  @moduledoc """
  Shared HTTP response helpers for LLMProxy Plug route modules.
  """

  import Plug.Conn

  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
