defmodule LLMProxy.HTTP.Router do
  @moduledoc """
  Standalone Plug router for LLMProxy health checks, core API routes, setup routes, and dynamic extensions.
  """

  use Plug.Router

  alias LLMProxy.HTTP
  alias LLMProxy.HTTP.ErrorResponse
  alias LLMProxy.HTTP.Routes.Dynamic
  alias LLMProxy.HTTP.RouteSpec

  plug(Plug.RequestId, assign_as: :request_id)

  plug(LLMProxy.Plugs.Drain)

  plug(:match)
  plug(:dispatch)

  get "/health" do
    drain = LLMProxy.Drain.status()

    HTTP.send_json(conn, 200, %{
      status: "ok",
      version: "0.1.0",
      ready: drain.ready,
      draining: drain.draining,
      serving: drain.serving,
      active: drain.active,
      concurrency: LLMProxy.ConcurrencyLimiter.status()
    })
  end

  for {path, plug} <- RouteSpec.routes() do
    forward(path, to: plug)
  end

  match _ do
    case Dynamic.dispatch(conn) do
      nil -> ErrorResponse.send(conn, 404, "not_found_error", "Not found")
      conn -> conn
    end
  end
end
