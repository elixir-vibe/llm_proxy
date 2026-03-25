defmodule LLMProxy.Routes.Stats do
  @moduledoc false
  use Plug.Router

  alias LLMProxy.Storage

  plug LLMProxy.Plugs.MasterKey
  plug :match
  plug :dispatch

  get "/" do
    stats = Storage.get_stats()
    send_json(conn, 200, stats)
  end

  get "/daily" do
    conn = fetch_query_params(conn)
    params = conn.query_params

    opts =
      %{}
      |> maybe_put(:start_date, params["start_date"])
      |> maybe_put(:end_date, params["end_date"])
      |> maybe_put(:group_by, params["group_by"])
      |> maybe_put(:key_id, params["key_id"])

    daily = Storage.get_daily_stats(opts)
    send_json(conn, 200, daily)
  end

  get "/messages" do
    conn = fetch_query_params(conn)
    params = conn.query_params

    opts =
      %{}
      |> maybe_put(:key_id, params["keyId"])
      |> maybe_put_int(:limit, params["limit"])
      |> maybe_put_int(:offset, params["offset"])

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_int(map, _key, nil), do: map
  defp maybe_put_int(map, _key, ""), do: map

  defp maybe_put_int(map, key, value) do
    case Integer.parse(value) do
      {int, _} -> Map.put(map, key, int)
      :error -> map
    end
  end
end
