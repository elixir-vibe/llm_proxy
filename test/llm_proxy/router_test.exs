defmodule LLMProxy.RouterDynamicTest do
  use ExUnit.Case

  alias LLMProxy.HTTP.Routes.Dynamic
  alias LLMProxy.Providers.Registry
  alias LLMProxy.Router

  defmodule RouterProvider do
    def name, do: "router-provider"
    def models, do: ["router-model"]
  end

  defmodule DynamicRoute do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      send_resp(conn, 200, "dynamic")
    end
  end

  setup do
    Registry.register(RouterProvider)
    Dynamic.init()
    Dynamic.register("/dynamic", DynamicRoute)
    :ok
  end

  test "serves the health endpoint" do
    conn = Plug.Test.conn(:get, "/health") |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end

  test "lists registered models" do
    conn = Plug.Test.conn(:get, "/v1/models") |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Enum.any?(Jason.decode!(conn.resp_body)["data"], &(&1["id"] == "router-model"))
  end

  test "dispatches dynamic routes and returns 404 otherwise" do
    dynamic_conn = Plug.Test.conn(:get, "/dynamic/test") |> Router.call(Router.init([]))
    missing_conn = Plug.Test.conn(:get, "/missing") |> Router.call(Router.init([]))

    assert dynamic_conn.status == 200
    assert dynamic_conn.resp_body == "dynamic"
    assert missing_conn.status == 404
    assert Jason.decode!(missing_conn.resp_body) == %{"error" => "Not found"}
  end
end
