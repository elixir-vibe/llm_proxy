defmodule LLMProxy.Plugs.Auth do
  @moduledoc """
  Extracts and validates API key from Authorization header or x-api-key.
  Assigns `:api_key` to the conn.
  """

  import Plug.Conn

  alias LLMProxy.Config
  alias LLMProxy.Storage

  def init(opts), do: opts

  def call(conn, _opts) do
    raw_key = extract_key(conn)

    cond do
      is_nil(raw_key) ->
        conn |> send_json(401, %{error: "Missing API key"}) |> halt()

      raw_key == Config.master_key() ->
        assign(conn, :api_key, master_key_struct())

      true ->
        case Storage.find_key(raw_key) do
          nil -> conn |> send_json(401, %{error: "Invalid API key"}) |> halt()
          key -> assign(conn, :api_key, key)
        end
    end
  end

  defp extract_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] -> key
      _ ->
        case get_req_header(conn, "x-api-key") do
          [key] -> key
          _ -> nil
        end
    end
  end

  defp master_key_struct do
    %{
      id: "master",
      name: "Master",
      quota_4h_input: nil,
      quota_4h_output: nil,
      quota_week_input: nil,
      quota_week_output: nil,
      quota_4h_messages: nil,
      quota_week_messages: nil,
      min_cache_ratio: nil,
      allowed_models: nil,
      service_quotas: nil
    }
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
