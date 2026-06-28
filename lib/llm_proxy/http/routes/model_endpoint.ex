defmodule LLMProxy.HTTP.Routes.ModelEndpoint do
  @moduledoc """
  Serves the OpenAI-compatible model list endpoint.
  """

  use Plug.Router

  alias LLMProxy.HTTP

  plug(:match)
  plug(:dispatch)

  get "/" do
    HTTP.send_json(conn, 200, %{object: "list", data: LLMProxy.Providers.Registry.all_models()})
  end

  match _ do
    HTTP.send_json(conn, 404, %{error: "Not found"})
  end
end
