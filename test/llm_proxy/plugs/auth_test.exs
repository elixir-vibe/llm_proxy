defmodule LLMProxy.Plugs.AuthTest do
  use ExUnit.Case

  import Plug.Test
  import Plug.Conn

  alias LLMProxy.Plugs.Auth
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo.SQLite

  alias Ecto.Adapters.SQL.Sandbox

  @master_key "test-master-key-xyz"

  setup do
    :ok = Sandbox.checkout(SQLite)
    Application.put_env(:llm_proxy, :master_key, @master_key)

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)
  end

  defp call_auth(conn) do
    Auth.call(conn, Auth.init([]))
  end

  describe "missing API key" do
    test "returns 401 when no auth header" do
      conn = conn(:get, "/") |> call_auth()

      assert conn.status == 401
      assert conn.halted

      assert %{
               "error" => %{
                 "message" => "Missing API key",
                 "type" => "authentication_error",
                 "code" => "authentication_error",
                 "status" => 401
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "returns 401 with empty Authorization header" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "")
        |> call_auth()

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "master key" do
    test "accepts master key via Bearer token" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{@master_key}")
        |> call_auth()

      refute conn.halted
      assert conn.assigns.api_key.id == "master"
      assert conn.assigns.api_key.name == "Master"
      assert conn.assigns.api_key.quota_4h_input == nil
      assert conn.assigns.api_key.allowed_models == nil
    end

    test "accepts master key via x-api-key header" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-api-key", @master_key)
        |> call_auth()

      refute conn.halted
      assert conn.assigns.api_key.id == "master"
    end
  end

  describe "API key from storage" do
    test "accepts valid API key" do
      {:ok, key, raw_key} = Storage.create_key("test-user")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> call_auth()

      refute conn.halted
      assert conn.assigns.api_key.id == key.id
      assert conn.assigns.api_key.name == "test-user"
    end

    test "accepts valid API key via x-api-key" do
      {:ok, key, raw_key} = Storage.create_key("alt-header-user")

      conn =
        conn(:get, "/")
        |> put_req_header("x-api-key", raw_key)
        |> call_auth()

      refute conn.halted
      assert conn.assigns.api_key.id == key.id
    end

    test "returns 401 for invalid API key" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer sk-proxy-invalid-key")
        |> call_auth()

      assert conn.status == 401
      assert conn.halted
      assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) == "Invalid API key"
    end
  end

  describe "header precedence" do
    test "Authorization header takes precedence over x-api-key" do
      {:ok, _key, raw_key} = Storage.create_key("precedence-user")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("x-api-key", "wrong-key")
        |> call_auth()

      refute conn.halted
      assert conn.assigns.api_key.name == "precedence-user"
    end
  end
end
