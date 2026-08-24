defmodule LLMProxy.HTTP.RouterTest do
  use ExUnit.Case

  alias LLMProxy.HTTP.Router
  alias LLMProxy.HTTP.Routes.Dynamic
  alias LLMProxy.Providers.Registry

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
    LLMProxy.Drain.cancel()
    Registry.register(RouterProvider)
    Dynamic.init()
    Dynamic.register("/dynamic", DynamicRoute)
    on_exit(fn -> LLMProxy.Drain.cancel() end)
    :ok
  end

  test "serves the health endpoint" do
    conn = Plug.Test.conn(:get, "/health") |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert body["ready"] == true
    assert body["draining"] == false
    assert body["active"] == %{"agents" => 0, "requests" => 0, "streams" => 0, "total" => 0}

    assert %{
             "active" => active,
             "admitted" => admitted,
             "rejected" => rejected,
             "released" => released
           } = body["concurrency"]

    assert Enum.all?([active, admitted, rejected, released], &is_integer/1)
  end

  test "health remains available while user routes reject during drain" do
    LLMProxy.Drain.start()

    health_conn = Plug.Test.conn(:get, "/health") |> Router.call(Router.init([]))
    models_conn = Plug.Test.conn(:get, "/v1/models") |> Router.call(Router.init([]))

    assert health_conn.status == 200
    assert Jason.decode!(health_conn.resp_body)["draining"] == true
    assert models_conn.status == 503
    assert Plug.Conn.get_resp_header(models_conn, "retry-after") == ["30"]
    assert Jason.decode!(models_conn.resp_body)["error"]["code"] == "draining"
  end

  test "lists registered models" do
    conn = Plug.Test.conn(:get, "/v1/models") |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Enum.any?(Jason.decode!(conn.resp_body)["data"], &(&1["id"] == "router-model"))
  end

  test "dispatches dynamic routes and returns 404 otherwise" do
    dynamic_conn = Plug.Test.conn(:get, "/dynamic/test") |> Router.call(Router.init([]))

    prefix_collision_conn =
      Plug.Test.conn(:get, "/dynamicity/test") |> Router.call(Router.init([]))

    missing_conn = Plug.Test.conn(:get, "/missing") |> Router.call(Router.init([]))

    assert dynamic_conn.status == 200
    assert dynamic_conn.resp_body == "dynamic"
    assert prefix_collision_conn.status == 404

    assert get_in(Jason.decode!(prefix_collision_conn.resp_body), ["error", "message"]) ==
             "Not found"

    assert missing_conn.status == 404
    assert get_in(Jason.decode!(missing_conn.resp_body), ["error", "message"]) == "Not found"
  end
end
