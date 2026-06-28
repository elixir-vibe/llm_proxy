defmodule LLMProxy.Plugs.Auth do
  @moduledoc """
  Extracts and validates API key from Authorization header or x-api-key.
  Assigns `:api_key` to the conn.
  """

  import Plug.Conn

  alias LLMProxy.{Actor, Config, HTTP, Storage}

  def init(opts), do: opts

  def call(conn, _opts) do
    raw_key = extract_key(conn)

    cond do
      is_nil(raw_key) ->
        conn |> HTTP.send_json(401, %{error: "Missing API key"}) |> halt()

      raw_key == Config.master_key() ->
        assign(conn, :api_key, Actor.master_key())

      true ->
        case Storage.find_key(raw_key) do
          nil -> conn |> HTTP.send_json(401, %{error: "Invalid API key"}) |> halt()
          key -> assign(conn, :api_key, key)
        end
    end
  end

  defp extract_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] ->
        key

      _ ->
        case get_req_header(conn, "x-api-key") do
          [key] -> key
          _ -> nil
        end
    end
  end
end
