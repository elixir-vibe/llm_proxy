defmodule LLMProxy.TestSupport do
  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox
  alias LLMProxy.Schemas.ProviderToken
  alias LLMProxy.Storage.Repo.SQLite

  def checkout_repo do
    :ok = Sandbox.checkout(SQLite)
    Sandbox.mode(SQLite, {:shared, self()})
  end

  def allow_token_pool do
    Sandbox.allow(SQLite, self(), Process.whereis(LLMProxy.TokenPool.Server))
  end

  def json_conn(method, path, body \\ %{}) do
    encoded = Jason.encode!(body)

    conn =
      conn(method, path, encoded)
      |> put_req_header("content-type", "application/json")

    parsers =
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason
      )

    Plug.Parsers.call(conn, parsers)
  end

  def clear_provider_tokens do
    SQLite.delete_all(ProviderToken)
  end

  def put_bearer(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
