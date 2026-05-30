defmodule LLMProxy.Routes.Tokens do
  @moduledoc false
  use Plug.Router

  alias LLMProxy.Plugs.MasterKey
  alias LLMProxy.Routes.Tokens.Params
  alias LLMProxy.Storage
  alias LLMProxy.TokenPool.Server, as: TokenPool

  plug(MasterKey)
  plug(:match)
  plug(:dispatch)

  get "/" do
    provider = conn.query_params["provider"]
    tokens = Storage.list_tokens(if provider, do: %{provider: provider}, else: %{})

    send_json(conn, 200, Enum.map(tokens, &serialize_token/1))
  end

  post "/clear-rate-limits" do
    TokenPool.clear_rate_limits()
    send_json(conn, 200, %{cleared: true})
  end

  post "/" do
    case Params.parse_create(conn.body_params) do
      {:ok, attrs} ->
        case Storage.add_token(attrs.provider, attrs.kind, attrs.token, %{
               label: attrs.label,
               proxy: attrs.proxy
             }) do
          {:ok, created} ->
            send_json(conn, 200, serialize_token(created))

          {:error, changeset} ->
            send_json(conn, 400, %{error: format_errors(changeset)})
        end

      {:error, message} ->
        send_json(conn, 400, %{error: message})
    end
  end

  delete "/:id" do
    case Storage.remove_token(String.to_integer(id)) do
      {:ok, _} -> send_json(conn, 200, %{deleted: true})
      {:error, :not_found} -> send_json(conn, 404, %{error: "Token not found"})
    end
  end

  patch "/:id" do
    id = String.to_integer(id)

    case Params.parse_update(conn.body_params) do
      {:ok, attrs} ->
        with :ok <- maybe_set_enabled(id, attrs),
             :ok <- maybe_update_proxy(id, attrs) do
          send_json(conn, 200, update_result(id, attrs))
        else
          {:error, :not_found} -> send_json(conn, 404, %{error: "Token not found"})
        end

      {:error, message} ->
        send_json(conn, 400, %{error: message})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp maybe_set_enabled(_id, %Params.Update{update_enabled?: false}), do: :ok

  defp maybe_set_enabled(id, %Params.Update{enabled: enabled}) do
    case Storage.set_token_enabled(id, enabled) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp maybe_update_proxy(_id, %Params.Update{update_proxy?: false}), do: :ok

  defp maybe_update_proxy(id, %Params.Update{proxy: proxy}) do
    case Storage.update_token_proxy(id, proxy) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp update_result(id, attrs) do
    %{id: id}
    |> maybe_put(:enabled, attrs.enabled, attrs.update_enabled?)
    |> maybe_put(:proxy, attrs.proxy, attrs.update_proxy?)
  end

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp mask_token(token) when byte_size(token) <= 12, do: "***"
  defp mask_token(token), do: String.slice(token, 0, 6) <> "..." <> String.slice(token, -4, 4)

  defp serialize_token(token) do
    %{
      id: token.id,
      provider: token.provider,
      kind: token.kind,
      token: mask_token(token.token),
      label: token.label,
      proxy: token.proxy,
      enabled: token.enabled,
      addedAt: DateTime.to_iso8601(token.added_at)
    }
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
