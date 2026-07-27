defmodule LLMProxy.HTTP.Routes.ModelEndpoint do
  @moduledoc """
  Serves the OpenAI-compatible model list endpoint.
  """

  use Plug.Router

  alias LLMProxy.HTTP
  alias LLMProxy.HTTP.ErrorResponse

  plug(:match)
  plug(:dispatch)

  get "/" do
    HTTP.send_json(conn, 200, %{object: "list", data: LLMProxy.Providers.Registry.all_models()})
  end

  match _ do
    ErrorResponse.send_openai(conn, 404, "not_found_error", "Not found")
  end
end
