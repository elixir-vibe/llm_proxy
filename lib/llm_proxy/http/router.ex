defmodule LLMProxy.HTTP.Router do
  @moduledoc false

  use Plug.Router

  alias LLMProxy.HTTP.Routes.Dynamic
  alias LLMProxy.HTTP.Routes.Helpers
  alias LLMProxy.HTTP.RouteSpec

  plug(:match)
  plug(:dispatch)

  get "/health" do
    Helpers.send_json(conn, 200, %{status: "ok", version: "0.1.0"})
  end

  for {path, plug} <- RouteSpec.routes() do
    forward(path, to: plug)
  end

  match _ do
    case Dynamic.dispatch(conn) do
      nil -> Helpers.send_json(conn, 404, %{error: "Not found"})
      conn -> conn
    end
  end
end
