defmodule LLMProxy.Routes.Context7 do
  use Plug.Router

  plug :match
  plug :dispatch

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(501, Jason.encode!(%{error: "Not implemented"}))
  end
end
