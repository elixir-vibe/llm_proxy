defmodule LLMProxy.HTTP.Routes.ModelEndpoint do
  @moduledoc """
  Serves the OpenAI-compatible model list endpoint.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_json(conn, 200, %{object: "list", data: LLMProxy.Providers.Registry.all_models()})
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
