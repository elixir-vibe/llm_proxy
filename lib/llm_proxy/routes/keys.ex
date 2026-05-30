defmodule LLMProxy.Routes.Keys do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.Plugs.{Auth, MasterKey}
  alias LLMProxy.Routes.Keys.Params
  alias LLMProxy.Storage

  @four_hours_ms 4 * 60 * 60 * 1000
  @one_week_ms 7 * 24 * 60 * 60 * 1000

  plug(:route_auth)
  plug(:match)
  plug(:dispatch)

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
    attrs = Params.parse_generate(conn.body_params)

    case Storage.create_key(attrs.name, attrs.opts) do
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
          max_budget_usd: key.max_budget_usd,
          budget_period: key.budget_period,
          budget_limits: key.budget_limits,
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
    case Params.parse_quota(conn.body_params) do
      {:ok, attrs} ->
        case Storage.update_key_quota(attrs.id, attrs.attrs) do
          {:ok, _} ->
            Logger.info("Updated quota for key id=#{attrs.id}")
            send_json(conn, 200, %{success: true})

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "Key not found"})

          {:error, changeset} ->
            Logger.error("Failed to update quota: #{inspect(changeset)}")
            send_json(conn, 500, %{error: "Failed to update quota"})
        end

      {:error, message} ->
        send_json(conn, 400, %{error: message})
    end
  end

  post "/models" do
    case Params.parse_models(conn.body_params) do
      {:ok, attrs} ->
        case Storage.update_key_models(attrs.id, attrs.allowed_models) do
          {:ok, _} ->
            Logger.info(
              "Updated models for key id=#{attrs.id} models=#{inspect(attrs.allowed_models)}"
            )

            send_json(conn, 200, %{success: true})

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "Key not found"})

          {:error, changeset} ->
            Logger.error("Failed to update models: #{inspect(changeset)}")
            send_json(conn, 500, %{error: "Failed to update models"})
        end

      {:error, message} ->
        send_json(conn, 400, %{error: message})
    end
  end

  post "/delete" do
    case Params.parse_delete(conn.body_params) do
      {:ok, attrs} ->
        case Storage.delete_key(attrs.id) do
          {:ok, _} ->
            Logger.info("Deleted key id=#{attrs.id}")
            send_json(conn, 200, %{success: true})

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "Key not found"})
        end

      {:error, message} ->
        send_json(conn, 400, %{error: message})
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
      max_budget_usd: key.max_budget_usd,
      budget_period: key.budget_period,
      budget_limits: key.budget_limits,
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

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
