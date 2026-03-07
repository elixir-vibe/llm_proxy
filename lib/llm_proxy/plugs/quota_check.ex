defmodule LlmProxy.Plugs.QuotaCheck do
  @moduledoc """
  Checks token/message/cache quotas for the authenticated API key.
  Must run after LlmProxy.Plugs.Auth.
  """

  import Plug.Conn

  alias LlmProxy.Storage

  def init(opts), do: opts

  def call(%{assigns: %{api_key: %{id: "master"}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    case Storage.check_quota(conn.assigns.api_key) do
      :ok -> conn
      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: reason}))
        |> halt()
    end
  end
end
