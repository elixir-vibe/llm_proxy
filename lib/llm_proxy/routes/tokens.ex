defmodule LLMProxy.Routes.Tokens do
  use Plug.Router

  alias LLMProxy.Plugs.MasterKey
  alias LLMProxy.Storage
  alias LLMProxy.TokenPool.Server, as: TokenPool

  plug MasterKey
  plug :match
  plug :dispatch

  get "/" do
    provider = conn.query_params["provider"]
    tokens = Storage.list_tokens(provider)

    send_json(conn, 200, Enum.map(tokens, &serialize_token/1))
  end

  post "/clear-rate-limits" do
    TokenPool.clear_rate_limits()
    send_json(conn, 200, %{cleared: true})
  end

  post "/" do
    body = conn.body_params
    provider = body["provider"]
    kind = body["kind"]
    token = body["token"]

    if is_nil(provider) or is_nil(kind) or is_nil(token) do
      send_json(conn, 400, %{error: "provider, kind, and token are required"})
    else
      case Storage.add_token(provider, kind, token, %{
             label: body["label"],
             proxy: body["proxy"]
           }) do
        {:ok, created} ->
          send_json(conn, 200, serialize_token(created))

        {:error, changeset} ->
          send_json(conn, 400, %{error: format_errors(changeset)})
      end
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
    body = conn.body_params
    enabled = body["enabled"]
    proxy = body["proxy"]

    if is_nil(enabled) and not Map.has_key?(body, "proxy") do
      send_json(conn, 400, %{error: "At least one of enabled or proxy is required"})
    else
      with :ok <- maybe_set_enabled(id, enabled),
           :ok <- maybe_update_proxy(id, body) do
        result = %{id: id}
        result = if not is_nil(enabled), do: Map.put(result, :enabled, enabled), else: result
        result = if Map.has_key?(body, "proxy"), do: Map.put(result, :proxy, proxy), else: result
        send_json(conn, 200, result)
      else
        {:error, :not_found} -> send_json(conn, 404, %{error: "Token not found"})
      end
    end
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp maybe_set_enabled(_id, nil), do: :ok

  defp maybe_set_enabled(id, enabled) do
    case Storage.set_token_enabled(id, enabled) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp maybe_update_proxy(id, body) do
    if Map.has_key?(body, "proxy") do
      case Storage.update_token_proxy(id, body["proxy"]) do
        {:ok, _} -> :ok
        {:error, :not_found} -> {:error, :not_found}
      end
    else
      :ok
    end
  end

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
