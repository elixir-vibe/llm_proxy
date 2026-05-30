defmodule LLMProxy.Routes.Stats do
  @moduledoc false
  use Plug.Router

  alias LLMProxy.Params
  alias LLMProxy.Storage

  plug(LLMProxy.Plugs.MasterKey)
  plug(:match)
  plug(:dispatch)

  get "/" do
    stats = Storage.get_stats()
    send_json(conn, 200, stats)
  end

  get "/daily" do
    conn = fetch_query_params(conn)
    params = conn.query_params

    opts =
      %{}
      |> Params.put_if_present(:start_date, params["start_date"])
      |> Params.put_if_present(:end_date, params["end_date"])
      |> Params.put_if_present(:group_by, params["group_by"])
      |> Params.put_if_present(:key_id, params["key_id"])

    daily = Storage.get_daily_stats(opts)
    send_json(conn, 200, daily)
  end

  get "/messages" do
    conn = fetch_query_params(conn)
    params = conn.query_params

    opts =
      %{}
      |> Params.put_if_present(:key_id, params["keyId"])
      |> Params.put_integer(:limit, params["limit"])
      |> Params.put_integer(:offset, params["offset"])

    messages = Storage.get_messages(opts)
    send_json(conn, 200, messages)
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
