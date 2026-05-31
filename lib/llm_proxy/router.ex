defmodule LLMProxy.Router do
  @moduledoc """
  Core LLM proxy router.

  Phoenix applications can either forward to this plug router directly or import
  the route forwards with `use LLMProxy.Router` and `llm_proxy_routes/0`.
  """

  use Plug.Router

  alias LLMProxy.HTTP.Routes.Dynamic

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

  plug(:match)
  plug(:dispatch)

  # Health check — no auth
  get "/health" do
    send_json(conn, 200, %{status: "ok", version: "0.1.0"})
  end

  # Forward to sub-routers
  forward("/v1/models", to: LLMProxy.HTTP.Routes.Models)
  forward("/models", to: LLMProxy.HTTP.Routes.Models)
  forward("/keys", to: LLMProxy.HTTP.Routes.Keys)
  forward("/tokens", to: LLMProxy.HTTP.Routes.Tokens)
  forward("/stats", to: LLMProxy.HTTP.Routes.Stats)
  forward("/v1/chat", to: LLMProxy.HTTP.Routes.Chat)
  forward("/chat", to: LLMProxy.HTTP.Routes.Chat)
  forward("/v1/messages", to: LLMProxy.HTTP.Routes.Messages)
  forward("/v1/responses", to: LLMProxy.HTTP.Routes.Responses)
  forward("/v1/moderations", to: LLMProxy.HTTP.Routes.Moderations)
  forward("/moderations", to: LLMProxy.HTTP.Routes.Moderations)
  # Dynamic routes registered by optional packages

  match _ do
    case Dynamic.dispatch(conn) do
      nil -> send_json(conn, 404, %{error: "Not found"})
      conn -> conn
    end
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

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
