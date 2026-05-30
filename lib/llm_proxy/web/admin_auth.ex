defmodule LLMProxy.Web.AdminAuth do
  @moduledoc false

  import Phoenix.LiveView

  def on_mount(:require_admin, _params, session, socket) do
    if session["admin_authenticated"] do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/admin/login")}
    end
  end
end
