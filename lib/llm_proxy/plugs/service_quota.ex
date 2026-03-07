defmodule LLMProxy.Plugs.ServiceQuota do
  @moduledoc false

  import Plug.Conn

  alias LLMProxy.Storage

  def init(opts), do: opts

  def call(conn, opts) do
    service = Keyword.fetch!(opts, :service)
    api_key = conn.assigns.api_key

    case Storage.check_service_quota(api_key, service) do
      :ok -> conn
      {:error, reason} -> conn |> send_json(429, %{error: reason}) |> halt()
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
