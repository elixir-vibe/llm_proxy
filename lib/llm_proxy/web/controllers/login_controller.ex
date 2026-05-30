defmodule LLMProxy.Web.LoginController do
  use Phoenix.Controller, formats: [:html]

  plug(:put_layout, html: {LLMProxy.Web.Layouts, :root})

  def index(conn, _params) do
    render(conn, :index, error: nil)
  end

  def create(conn, %{"password" => password}) do
    if LLMProxy.Config.valid_master_key?(password) do
      conn
      |> put_session(:admin_authenticated, true)
      |> redirect(to: "/admin")
    else
      render(conn, :index, error: "Invalid master key")
    end
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/admin/login")
  end
end
