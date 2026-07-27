defmodule LLMProxy.Plugs.QuotaCheck do
  @moduledoc """
  Checks token/message/cache quotas for the authenticated API key.
  Must run after LLMProxy.Plugs.Auth.
  """

  import Plug.Conn

  alias LLMProxy.HTTP.ErrorResponse
  alias LLMProxy.Storage

  def init(opts), do: opts

  def call(%{assigns: %{api_key: %{id: "master"}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    case Storage.check_quota(conn.assigns.api_key) do
      :ok ->
        conn

      {:error, reason} ->
        conn
        |> ErrorResponse.send(429, "rate_limit_error", reason)
        |> halt()
    end
  end
end
