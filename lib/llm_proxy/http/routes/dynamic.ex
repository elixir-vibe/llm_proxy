defmodule LLMProxy.HTTP.Routes.Dynamic do
  @moduledoc """
  Registry for dynamically registered routes from optional packages.

  Private repo registers its routes at startup:

      LLMProxy.HTTP.Routes.Dynamic.register("/v1/messages", LLMProxyPrivate.Routes.Messages)
      LLMProxy.HTTP.Routes.Dynamic.register("/v1/responses", LLMProxyPrivate.Routes.Responses)
  """

  @registry_key :llm_proxy_dynamic_routes

  def init do
    :persistent_term.put(@registry_key, [])
  end

  def register(prefix, plug_module) do
    routes = :persistent_term.get(@registry_key, [])
    :persistent_term.put(@registry_key, [{prefix, plug_module} | routes])
    :ok
  end

  def dispatch(conn) do
    path = IO.iodata_to_binary(["/", Enum.intersperse(conn.path_info, "/")])
    routes = :persistent_term.get(@registry_key, [])

    Enum.find_value(routes, fn {prefix, plug_module} ->
      if String.starts_with?(path, prefix) do
        remaining = String.replace_prefix(path, prefix, "")

        remaining_segments =
          remaining
          |> String.split("/", trim: true)

        conn = %{
          conn
          | path_info: remaining_segments,
            script_name: conn.script_name ++ String.split(prefix, "/", trim: true)
        }

        plug_module.call(conn, plug_module.init([]))
      end
    end)
  end
end
