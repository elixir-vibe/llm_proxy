defmodule LLMProxy.Phoenix.Router do
  @moduledoc false

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
    core? = Keyword.get(opts, :core, true)
    admin? = Keyword.get(opts, :admin, true)
    setup? = Keyword.get(opts, :setup, false)

    routes =
      []
      |> maybe_add_core(path, core?)
      |> maybe_add_admin(path, admin?)
      |> maybe_add_setup(path, setup?)

    quote do
      (unquote_splicing(routes))
    end
  end

  defp maybe_add_core(routes, _path, false), do: routes

  defp maybe_add_core(routes, path, true) do
    routes ++
      [
        route(path, "/v1/models", LLMProxy.HTTP.Routes.Models),
        route(path, "/models", LLMProxy.HTTP.Routes.Models),
        route(path, "/v1/chat", LLMProxy.HTTP.Routes.Chat),
        route(path, "/chat", LLMProxy.HTTP.Routes.Chat),
        route(path, "/v1/messages", LLMProxy.HTTP.Routes.Messages),
        route(path, "/v1/responses", LLMProxy.HTTP.Routes.Responses),
        route(path, "/v1/moderations", LLMProxy.HTTP.Routes.Moderations),
        route(path, "/moderations", LLMProxy.HTTP.Routes.Moderations)
      ]
  end

  defp maybe_add_admin(routes, _path, false), do: routes

  defp maybe_add_admin(routes, path, true) do
    routes ++
      [
        route(path, "/keys", LLMProxy.HTTP.Routes.Keys),
        route(path, "/tokens", LLMProxy.HTTP.Routes.Tokens),
        route(path, "/stats", LLMProxy.HTTP.Routes.Stats)
      ]
  end

  defp maybe_add_setup(routes, _path, false), do: routes

  defp maybe_add_setup(routes, path, true),
    do: routes ++ [route(path, "/setup", LLMProxy.HTTP.Routes.Setup)]

  defp route(path, suffix, plug) do
    route_path = path |> String.trim_trailing("/") |> Kernel.<>(suffix)
    route_path = if route_path == "", do: "/", else: route_path

    quote do
      Phoenix.Router.forward(unquote(route_path), unquote(plug), [])
    end
  end
end
