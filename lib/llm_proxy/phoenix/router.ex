defmodule LLMProxy.Phoenix.Router do
  @moduledoc false

  alias LLMProxy.HTTP.RouteSpec

  defmacro __using__(opts \\ []) do
    opts = Macro.expand(opts, __CALLER__)

    routes =
      if Enum.any?([:mount, :core, :admin, :setup], &Keyword.has_key?(opts, &1)) do
        build_routes(Keyword.get(opts, :mount, "/"), opts)
      else
        quote(do: nil)
      end

    quote do
      import LLMProxy.Router,
        only: [llm_proxy: 1, llm_proxy: 2, llm_proxy_routes: 0, llm_proxy_routes: 1]

      unquote(routes)
    end
  end

  defmacro llm_proxy_routes(opts \\ []) do
    opts = Macro.expand(opts, __CALLER__)
    path = Keyword.get(opts, :mount, "/")

    build_routes(path, opts)
  end

  defmacro llm_proxy(path, opts \\ []) do
    build_routes(Macro.expand(path, __CALLER__), Macro.expand(opts, __CALLER__))
  end

  def __routes_ast__(path, opts), do: build_routes(path, opts)

  defp build_routes(path, opts) when is_binary(path) and is_list(opts) do
    routes =
      opts
      |> RouteSpec.routes()
      |> Enum.map(fn {suffix, plug} -> route(path, suffix, plug) end)

    quote do
      (unquote_splicing(routes))
    end
  end

  defp route(path, suffix, plug) do
    route_path = path |> String.trim_trailing("/") |> Kernel.<>(suffix)
    route_path = if route_path == "", do: "/", else: route_path

    quote do
      Phoenix.Router.forward(unquote(route_path), unquote(plug), [])
    end
  end
end
