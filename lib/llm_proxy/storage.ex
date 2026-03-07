defmodule LLMProxy.Storage do
  @moduledoc """
  Context functions for all database operations: keys, usage, quotas, tokens.
  """

  alias LLMProxy.Repo
  alias LLMProxy.Schemas.{ApiKey, UsageLog, ServiceUsage, ProviderToken, MessageLog}

  import Ecto.Query

  @four_hours_ms 4 * 60 * 60 * 1000
  @one_week_ms 7 * 24 * 60 * 60 * 1000
  @min_tokens_for_ratio_check 50_000

  # --- API Keys ---

  def create_key(name, opts \\ %{}) do
    raw_key = "sk-proxy-#{generate_uuid()}"
    hash = hash_key(raw_key)
    id = generate_uuid()

    attrs =
      Map.merge(opts, %{id: id, hash: hash, name: name})

    case %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert() do
      {:ok, key} -> {:ok, key, raw_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def find_key(raw_key) do
    hash = hash_key(raw_key)
    Repo.get_by(ApiKey, hash: hash)
  end

  def list_keys do
    ApiKey |> order_by(desc: :inserted_at) |> Repo.all()
  end

  def delete_key(id) do
    case Repo.get(ApiKey, id) do
      nil -> {:error, :not_found}
      key ->
        Repo.delete_all(from u in UsageLog, where: u.key_id == ^id)
        Repo.delete(key)
    end
  end

  def update_key_usage(key, %{input: input, output: output} = usage) do
    cache_read = Map.get(usage, :cache_read, 0)
    cache_write = Map.get(usage, :cache_write, 0)

    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all(
      inc: [
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: cache_read,
        cache_write_tokens: cache_write
      ]
    )
  end

  def update_key_quota(id, quota_attrs) do
    case Repo.get(ApiKey, id) do
      nil -> {:error, :not_found}
      key -> key |> ApiKey.changeset(quota_attrs) |> Repo.update()
    end
  end

  def update_key_models(id, allowed_models) do
    case Repo.get(ApiKey, id) do
      nil -> {:error, :not_found}
      key -> key |> ApiKey.changeset(%{allowed_models: allowed_models}) |> Repo.update()
    end
  end

  def check_model_access(key, model) do
    case key.allowed_models do
      nil -> :ok
      models when is_list(models) ->
        if model in models, do: :ok, else: {:error, "Model '#{model}' not allowed. Allowed: #{Enum.join(models, ", ")}"}
    end
  end

  # --- Usage Tracking ---

  def record_usage(attrs) do
    %UsageLog{}
    |> UsageLog.changeset(attrs)
    |> Repo.insert()
  end

  def get_usage_in_window(key_id, window_ms) do
    since = DateTime.add(DateTime.utc_now(), -window_ms, :millisecond)

    result =
      from(u in UsageLog,
        where: u.key_id == ^key_id and u.timestamp >= ^since,
        select: %{
          input: coalesce(sum(u.input_tokens), 0),
          output: coalesce(sum(u.output_tokens), 0)
        }
      )
      |> Repo.one()

    result || %{input: 0, output: 0}
  end

  def get_message_count_in_window(key_id, window_ms) do
    since = DateTime.add(DateTime.utc_now(), -window_ms, :millisecond)

    from(u in UsageLog,
      where: u.key_id == ^key_id and u.timestamp >= ^since,
      select: count(u.id)
    )
    |> Repo.one() || 0
  end

  def get_cache_ratio_in_window(key_id, window_ms) do
    since = DateTime.add(DateTime.utc_now(), -window_ms, :millisecond)

    result =
      from(u in UsageLog,
        where: u.key_id == ^key_id and u.timestamp >= ^since,
        select: %{
          input: coalesce(sum(u.input_tokens), 0),
          cache_read: coalesce(sum(u.cache_read_tokens), 0)
        }
      )
      |> Repo.one()

    input = result.input
    cache_read = result.cache_read
    total = input + cache_read

    ratio = if total > 0, do: cache_read / total, else: 1.0
    {ratio, total}
  end

  # --- Quota Checking ---

  def check_quota(key) do
    with :ok <- check_4h_token_quota(key),
         :ok <- check_week_token_quota(key),
         :ok <- check_4h_message_quota(key),
         :ok <- check_week_message_quota(key),
         :ok <- check_cache_ratio(key) do
      :ok
    end
  end

  defp check_4h_token_quota(%{quota_4h_input: nil, quota_4h_output: nil}), do: :ok

  defp check_4h_token_quota(key) do
    usage = get_usage_in_window(key.id, @four_hours_ms)

    cond do
      key.quota_4h_input && usage.input >= key.quota_4h_input ->
        {:error, "4h input quota exceeded (#{usage.input}/#{key.quota_4h_input})"}

      key.quota_4h_output && usage.output >= key.quota_4h_output ->
        {:error, "4h output quota exceeded (#{usage.output}/#{key.quota_4h_output})"}

      true ->
        :ok
    end
  end

  defp check_week_token_quota(%{quota_week_input: nil, quota_week_output: nil}), do: :ok

  defp check_week_token_quota(key) do
    usage = get_usage_in_window(key.id, @one_week_ms)

    cond do
      key.quota_week_input && usage.input >= key.quota_week_input ->
        {:error, "Weekly input quota exceeded (#{usage.input}/#{key.quota_week_input})"}

      key.quota_week_output && usage.output >= key.quota_week_output ->
        {:error, "Weekly output quota exceeded (#{usage.output}/#{key.quota_week_output})"}

      true ->
        :ok
    end
  end

  defp check_4h_message_quota(%{quota_4h_messages: nil}), do: :ok

  defp check_4h_message_quota(key) do
    count = get_message_count_in_window(key.id, @four_hours_ms)

    if count >= key.quota_4h_messages do
      {:error, "4h message quota exceeded (#{count}/#{key.quota_4h_messages})"}
    else
      :ok
    end
  end

  defp check_week_message_quota(%{quota_week_messages: nil}), do: :ok

  defp check_week_message_quota(key) do
    count = get_message_count_in_window(key.id, @one_week_ms)

    if count >= key.quota_week_messages do
      {:error, "Weekly message quota exceeded (#{count}/#{key.quota_week_messages})"}
    else
      :ok
    end
  end

  defp check_cache_ratio(%{min_cache_ratio: nil}), do: :ok

  defp check_cache_ratio(key) do
    {ratio, total} = get_cache_ratio_in_window(key.id, @four_hours_ms)

    if total >= @min_tokens_for_ratio_check and ratio < key.min_cache_ratio do
      pct = Float.round(ratio * 100, 1)
      min_pct = Float.round(key.min_cache_ratio * 100, 1)
      {:error, "Cache hit ratio too low: #{pct}% (minimum: #{min_pct}%). Fix your prompt caching to continue."}
    else
      :ok
    end
  end

  # --- Service Usage ---

  def record_service_usage(attrs) do
    %ServiceUsage{}
    |> ServiceUsage.changeset(attrs)
    |> Repo.insert()
  end

  def get_service_usage_in_window(key_id, service, window_ms) do
    since = DateTime.add(DateTime.utc_now(), -window_ms, :millisecond)

    from(s in ServiceUsage,
      where: s.key_id == ^key_id and s.service == ^service and s.timestamp >= ^since,
      select: count(s.id)
    )
    |> Repo.one() || 0
  end

  def check_service_quota(key, service) do
    quotas = get_in(key.service_quotas || %{}, [service])

    case quotas do
      nil -> :ok
      quotas -> do_check_service_quota(key.id, service, quotas)
    end
  end

  defp do_check_service_quota(key_id, service, quotas) do
    with :ok <- check_service_4h(key_id, service, quotas),
         :ok <- check_service_week(key_id, service, quotas) do
      :ok
    end
  end

  defp check_service_4h(key_id, service, %{"4h" => limit}) when is_integer(limit) do
    usage = get_service_usage_in_window(key_id, service, @four_hours_ms)

    if usage >= limit do
      {:error, "#{service} 4h quota exceeded (#{usage}/#{limit} requests)"}
    else
      :ok
    end
  end

  defp check_service_4h(_, _, _), do: :ok

  defp check_service_week(key_id, service, %{"week" => limit}) when is_integer(limit) do
    usage = get_service_usage_in_window(key_id, service, @one_week_ms)

    if usage >= limit do
      {:error, "#{service} weekly quota exceeded (#{usage}/#{limit} requests)"}
    else
      :ok
    end
  end

  defp check_service_week(_, _, _), do: :ok

  # --- Provider Tokens ---

  def get_tokens(provider, kind) do
    ProviderToken
    |> where([t], t.provider == ^provider and t.kind == ^kind and t.enabled == true)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  def list_tokens(provider \\ nil) do
    query = ProviderToken |> order_by([:provider, :id])
    query = if provider, do: where(query, [t], t.provider == ^provider), else: query
    Repo.all(query)
  end

  def add_token(provider, kind, token, opts \\ %{}) do
    %ProviderToken{}
    |> ProviderToken.changeset(
      Map.merge(opts, %{provider: provider, kind: kind, token: token, added_at: DateTime.utc_now()})
    )
    |> Repo.insert()
  end

  def remove_token(id) do
    case Repo.get(ProviderToken, id) do
      nil -> {:error, :not_found}
      token -> Repo.delete(token)
    end
  end

  def set_token_enabled(id, enabled) do
    case Repo.get(ProviderToken, id) do
      nil -> {:error, :not_found}
      token -> token |> ProviderToken.changeset(%{enabled: enabled}) |> Repo.update()
    end
  end

  def update_token_proxy(id, proxy) do
    case Repo.get(ProviderToken, id) do
      nil -> {:error, :not_found}
      token -> token |> ProviderToken.changeset(%{proxy: proxy}) |> Repo.update()
    end
  end

  def seed_tokens_from_env(entries) do
    for %{provider: provider, kind: kind, tokens: tokens} <- entries do
      existing =
        ProviderToken
        |> where([t], t.provider == ^provider and t.kind == ^kind)
        |> select([t], t.token)
        |> Repo.all()
        |> MapSet.new()

      for token <- tokens, token not in existing do
        add_token(provider, kind, token, %{label: "env"})
      end
    end
  end

  # --- Message Log ---

  def log_message(attrs) do
    %MessageLog{}
    |> MessageLog.changeset(Map.put(attrs, :timestamp, DateTime.utc_now()))
    |> Repo.insert()
  end

  def get_messages(opts \\ %{}) do
    query =
      from(m in MessageLog,
        join: k in ApiKey,
        on: k.id == m.key_id,
        order_by: [desc: m.timestamp],
        select: %{
          id: m.id,
          key_id: m.key_id,
          key_name: k.name,
          model: m.model,
          route: m.route,
          user_message: m.user_message,
          timestamp: m.timestamp
        }
      )

    query = if opts[:key_id], do: where(query, [m], m.key_id == ^opts.key_id), else: query
    query = query |> limit(^Map.get(opts, :limit, 50))
    query = if opts[:offset], do: offset(query, ^opts.offset), else: query

    Repo.all(query)
  end

  # --- Stats ---

  def get_stats do
    key_stats =
      from(k in ApiKey,
        select: %{
          count: count(k.id),
          input: coalesce(sum(k.input_tokens), 0),
          output: coalesce(sum(k.output_tokens), 0),
          cache_read: coalesce(sum(k.cache_read_tokens), 0),
          cache_write: coalesce(sum(k.cache_write_tokens), 0)
        }
      )
      |> Repo.one()

    request_count = from(u in UsageLog, select: count(u.id)) |> Repo.one()

    recent =
      UsageLog
      |> order_by(desc: :timestamp)
      |> limit(50)
      |> Repo.all()

    service_stats =
      from(s in ServiceUsage,
        group_by: s.service,
        select: %{service: s.service, count: count(s.id)}
      )
      |> Repo.all()

    %{
      total_keys: key_stats.count,
      total_requests: request_count,
      total_input_tokens: key_stats.input,
      total_output_tokens: key_stats.output,
      total_cache_read_tokens: key_stats.cache_read,
      total_cache_write_tokens: key_stats.cache_write,
      recent_usage: recent,
      service_stats: service_stats
    }
  end

  # --- Helpers ---

  defp hash_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end

  defp generate_uuid, do: Ecto.UUID.generate()
end
