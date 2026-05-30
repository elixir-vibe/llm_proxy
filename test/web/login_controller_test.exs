defmodule LLMProxy.Web.LoginControllerTest do
  use ExUnit.Case

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint LLMProxy.Web.Endpoint

  setup do
    Application.put_env(:llm_proxy, :master_key, "admin-secret")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)
  end

  test "renders the login page" do
    conn = get(build_conn(), "/admin/login")

    assert html_response(conn, 200) =~ "LLM Proxy Admin"
    assert html_response(conn, 200) =~ "Sign in"
  end

  test "authenticates and redirects with the correct password" do
    conn = post(build_conn(), "/admin/login", %{"password" => "admin-secret"})

    assert redirected_to(conn) == "/admin"
    assert get_session(conn, :admin_authenticated)
  end

  test "re-renders the form for invalid passwords" do
    conn = post(build_conn(), "/admin/login", %{"password" => "wrong"})

    assert html_response(conn, 200) =~ "Invalid master key"
  end

  test "does not authenticate when the master key is not configured" do
    Application.delete_env(:llm_proxy, :master_key)

    conn = post(build_conn(), "/admin/login", %{"password" => ""})

    assert html_response(conn, 200) =~ "Invalid master key"
    refute get_session(conn, :admin_authenticated)
  end

  test "clears the session on logout" do
    conn =
      build_conn()
      |> init_test_session(admin_authenticated: true)
      |> get("/admin/logout")

    assert redirected_to(conn) == "/admin/login"
    refute get_session(conn, :admin_authenticated)
  end
end
