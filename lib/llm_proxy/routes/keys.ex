defmodule LLMProxy.Routes.Keys do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.Plugs.{Auth, MasterKey}
  alias LLMProxy.Storage

  @four_hours_ms 4 * 60 * 60 * 1000
  @one_week_ms 7 * 24 * 60 * 60 * 1000

  plug :route_auth
  plug :match
  plug :dispatch

  # --- Self-service endpoint (any valid API key) ---

  get "/usage" do
    api_key = conn.assigns.api_key

    usage_4h = Storage.get_usage_in_window(api_key.id, @four_hours_ms)
    usage_week = Storage.get_usage_in_window(api_key.id, @one_week_ms)
    messages_4h = Storage.get_message_count_in_window(api_key.id, @four_hours_ms)
    messages_week = Storage.get_message_count_in_window(api_key.id, @one_week_ms)
    {cache_ratio_4h, _total} = Storage.get_cache_ratio_in_window(api_key.id, @four_hours_ms)

    send_json(conn, 200, %{
      name: api_key.name,
      usage_4h: usage_4h,
      usage_week: usage_week,
      messages_4h: messages_4h,
      messages_week: messages_week,
      cache_ratio_4h: cache_ratio_4h,
      quota_4h_input: api_key.quota_4h_input,
      quota_4h_output: api_key.quota_4h_output,
      quota_week_input: api_key.quota_week_input,
      quota_week_output: api_key.quota_week_output,
      quota_4h_messages: api_key.quota_4h_messages,
      quota_week_messages: api_key.quota_week_messages,
      min_cache_ratio: api_key.min_cache_ratio,
      total_tokens: %{
        input: api_key.input_tokens,
        output: api_key.output_tokens,
        cache_read: api_key.cache_read_tokens,
        cache_write: api_key.cache_write_tokens
      }
    })
  end

  # --- Admin endpoints (master key required) ---

  post "/generate" do
    body = conn.body_params

    opts =
      %{}
      |> put_if_present(:quota_4h_input, body["quota_4h_input"])
      |> put_if_present(:quota_4h_output, body["quota_4h_output"])
      |> put_if_present(:quota_week_input, body["quota_week_input"])
      |> put_if_present(:quota_week_output, body["quota_week_output"])
      |> put_if_present(:quota_4h_messages, body["quota_4h_messages"])
      |> put_if_present(:quota_week_messages, body["quota_week_messages"])
      |> put_if_present(:min_cache_ratio, body["min_cache_ratio"])
      |> put_if_present(:allowed_models, body["allowed_models"])
      |> put_if_present(:service_quotas, body["service_quotas"])

    name = body["name"] || "Unnamed"

    case Storage.create_key(name, opts) do
      {:ok, key, raw_key} ->
        Logger.info("Generated key #{key.name} id=#{key.id}")

        send_json(conn, 200, %{
          id: key.id,
          key: raw_key,
          name: key.name,
          created_at: key.inserted_at,
          quota_4h_input: key.quota_4h_input,
          quota_4h_output: key.quota_4h_output,
          quota_week_input: key.quota_week_input,
          quota_week_output: key.quota_week_output,
          quota_4h_messages: key.quota_4h_messages,
          quota_week_messages: key.quota_week_messages,
          min_cache_ratio: key.min_cache_ratio,
          allowed_models: key.allowed_models,
          service_quotas: key.service_quotas
        })

      {:error, changeset} ->
        Logger.error("Failed to create key: #{inspect(changeset)}")
        send_json(conn, 500, %{error: "Failed to create key"})
    end
  end

  get "/" do
    keys = Storage.list_keys()
    keys_with_usage = Enum.map(keys, &key_with_usage/1)
    send_json(conn, 200, %{keys: keys_with_usage})
  end

  get "/:id" do
    keys = Storage.list_keys()

    case Enum.find(keys, fn k -> k.id == id end) do
      nil ->
        send_json(conn, 404, %{error: "Key not found"})

      key ->
        send_json(conn, 200, key_with_usage(key))
    end
  end

  post "/quota" do
    body = conn.body_params
    id = body["id"]

    has_token_quotas =
      Map.has_key?(body, "quota_4h_input") or
        Map.has_key?(body, "quota_4h_output") or
        Map.has_key?(body, "quota_week_input") or
        Map.has_key?(body, "quota_week_output") or
        Map.has_key?(body, "quota_4h_messages") or
        Map.has_key?(body, "quota_week_messages") or
        Map.has_key?(body, "min_cache_ratio")

    has_service_quotas = Map.has_key?(body, "service_quotas")

    if not has_token_quotas and not has_service_quotas do
      send_json(conn, 400, %{error: "No quota fields provided"})
    else
      result =
        if has_token_quotas do
          quota_attrs =
            %{}
            |> put_if_has_key(body, "quota_4h_input")
            |> put_if_has_key(body, "quota_4h_output")
            |> put_if_has_key(body, "quota_week_input")
            |> put_if_has_key(body, "quota_week_output")
            |> put_if_has_key(body, "quota_4h_messages")
            |> put_if_has_key(body, "quota_week_messages")
            |> put_if_has_key(body, "min_cache_ratio")

          Storage.update_key_quota(id, quota_attrs)
        else
          {:ok, nil}
        end

      result =
        if has_service_quotas do
          Storage.update_key_quota(id, %{service_quotas: body["service_quotas"]})
        else
          result
        end

      case result do
        {:ok, _} ->
          Logger.info("Updated quota for key id=#{id}")
          send_json(conn, 200, %{success: true})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "Key not found"})

        {:error, changeset} ->
          Logger.error("Failed to update quota: #{inspect(changeset)}")
          send_json(conn, 500, %{error: "Failed to update quota"})
      end
    end
  end

  post "/models" do
    body = conn.body_params
    id = body["id"]
    allowed_models = body["allowed_models"]

    case Storage.update_key_models(id, allowed_models) do
      {:ok, _} ->
        Logger.info("Updated models for key id=#{id} models=#{inspect(allowed_models)}")
        send_json(conn, 200, %{success: true})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "Key not found"})

      {:error, changeset} ->
        Logger.error("Failed to update models: #{inspect(changeset)}")
        send_json(conn, 500, %{error: "Failed to update models"})
    end
  end

  post "/delete" do
    body = conn.body_params
    id = body["id"]

    case Storage.delete_key(id) do
      {:ok, _} ->
        Logger.info("Deleted key id=#{id}")
        send_json(conn, 200, %{success: true})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "Key not found"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  # --- Private helpers ---

  defp key_with_usage(key) do
    usage_4h = Storage.get_usage_in_window(key.id, @four_hours_ms)
    usage_week = Storage.get_usage_in_window(key.id, @one_week_ms)
    messages_4h = Storage.get_message_count_in_window(key.id, @four_hours_ms)
    messages_week = Storage.get_message_count_in_window(key.id, @one_week_ms)
    {cache_ratio_4h, _total} = Storage.get_cache_ratio_in_window(key.id, @four_hours_ms)

    %{
      id: key.id,
      name: key.name,
      created_at: key.inserted_at,
      quota_4h_input: key.quota_4h_input,
      quota_4h_output: key.quota_4h_output,
      quota_week_input: key.quota_week_input,
      quota_week_output: key.quota_week_output,
      quota_4h_messages: key.quota_4h_messages,
      quota_week_messages: key.quota_week_messages,
      min_cache_ratio: key.min_cache_ratio,
      allowed_models: key.allowed_models,
      service_quotas: key.service_quotas,
      usage_4h: usage_4h,
      usage_week: usage_week,
      messages_4h: messages_4h,
      messages_week: messages_week,
      cache_ratio_4h: cache_ratio_4h,
      input_tokens: key.input_tokens,
      output_tokens: key.output_tokens,
      cache_read_tokens: key.cache_read_tokens,
      cache_write_tokens: key.cache_write_tokens
    }
  end

  defp route_auth(conn, _opts) do
    if conn.path_info == ["usage"] and conn.method == "GET" do
      Auth.call(conn, Auth.init([]))
    else
      MasterKey.call(conn, MasterKey.init([]))
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_if_has_key(map, body, json_key) do
    atom_key = String.to_existing_atom(json_key)

    if Map.has_key?(body, json_key) do
      Map.put(map, atom_key, body[json_key])
    else
      map
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
