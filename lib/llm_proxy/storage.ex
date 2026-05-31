defmodule LLMProxy.Storage do
  @moduledoc """
  Context functions for all database operations: keys, usage, quotas, tokens.
  """

  alias LLMProxy.Storage.{Repo, SQL}

  alias LLMProxy.Schemas.{
    ApiKey,
    MessageLog,
    ProviderToken,
    ServiceUsage,
    Trace,
    TraceFeedback,
    UsageLog
  }

  import Ecto.Query

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

  def list_keys(opts \\ %{}) do
    query = from(k in ApiKey)

    query =
      apply_sort(query, opts[:sort], opts[:dir], [
        :name,
        :input_tokens,
        :output_tokens,
        :cache_read_tokens
      ])

    query = if query_has_order?(query), do: query, else: order_by(query, desc: :inserted_at)
    Repo.all(query)
  end

  def delete_key(id) do
    case Repo.get(ApiKey, id) do
      nil ->
        {:error, :not_found}

      key ->
        Repo.delete_all(from(u in UsageLog, where: u.key_id == ^id))
        Repo.delete(key)
    end
  end

  def update_key_usage(key, %{input: input, output: output} = usage) do
    cache_read = Map.get(usage, :cache_read, 0)
    cache_write = Map.get(usage, :cache_write, 0)
    cost_usd = Map.get(usage, :cost_usd, 0.0)

    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all(
      inc: [
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: cache_read,
        cache_write_tokens: cache_write,
        total_spend_usd: cost_usd
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
      nil ->
        :ok

      models when is_list(models) ->
        if model in models,
          do: :ok,
          else: {:error, "Model '#{model}' not allowed. Allowed: #{Enum.join(models, ", ")}"}
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
    with :ok <- LLMProxy.Limits.check(key),
         :ok <- check_budget(key),
         :ok <- check_4h_token_quota(key),
         :ok <- check_week_token_quota(key),
         :ok <- check_4h_message_quota(key),
         :ok <- check_week_message_quota(key) do
      check_cache_ratio(key)
    end
  end

  defp check_budget(%{max_budget_usd: nil}), do: :ok

  defp check_budget(key) do
    spend = get_budget_spend(key)

    if spend >= key.max_budget_usd do
      {:error,
       "Budget exceeded ($#{Float.round(spend, 2)}/$#{Float.round(key.max_budget_usd, 2)})"}
    else
      :ok
    end
  end

  defp get_budget_spend(%{budget_period: period} = key) when period in ["4h", "week"] do
    window_ms =
      case period do
        "4h" -> LLMProxy.Config.usage_window_4h_ms()
        "week" -> LLMProxy.Config.usage_window_week_ms()
      end

    result =
      from(u in UsageLog,
        where:
          u.key_id == ^key.id and
            u.timestamp >= ^DateTime.add(DateTime.utc_now(), -window_ms, :millisecond),
        select: coalesce(sum(u.cost_usd), 0.0)
      )
      |> Repo.one()

    result || 0.0
  end

  defp get_budget_spend(key) do
    key.total_spend_usd || 0.0
  end

  defp check_4h_token_quota(%{quota_4h_input: nil, quota_4h_output: nil}), do: :ok

  defp check_4h_token_quota(key) do
    usage = get_usage_in_window(key.id, LLMProxy.Config.usage_window_4h_ms())

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
    usage = get_usage_in_window(key.id, LLMProxy.Config.usage_window_week_ms())

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
    count = get_message_count_in_window(key.id, LLMProxy.Config.usage_window_4h_ms())

    if count >= key.quota_4h_messages do
      {:error, "4h message quota exceeded (#{count}/#{key.quota_4h_messages})"}
    else
      :ok
    end
  end

  defp check_week_message_quota(%{quota_week_messages: nil}), do: :ok

  defp check_week_message_quota(key) do
    count = get_message_count_in_window(key.id, LLMProxy.Config.usage_window_week_ms())

    if count >= key.quota_week_messages do
      {:error, "Weekly message quota exceeded (#{count}/#{key.quota_week_messages})"}
    else
      :ok
    end
  end

  defp check_cache_ratio(%{min_cache_ratio: nil}), do: :ok

  defp check_cache_ratio(key) do
    {ratio, total} = get_cache_ratio_in_window(key.id, LLMProxy.Config.usage_window_4h_ms())

    if total >= @min_tokens_for_ratio_check and ratio < key.min_cache_ratio do
      pct = Float.round(ratio * 100, 1)
      min_pct = Float.round(key.min_cache_ratio * 100, 1)

      {:error,
       "Cache hit ratio too low: #{pct}% (minimum: #{min_pct}%). Fix your prompt caching to continue."}
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
    with :ok <- check_service_4h(key_id, service, quotas) do
      check_service_week(key_id, service, quotas)
    end
  end

  defp check_service_4h(key_id, service, %{"4h" => limit}) when is_integer(limit) do
    usage = get_service_usage_in_window(key_id, service, LLMProxy.Config.usage_window_4h_ms())

    if usage >= limit do
      {:error, "#{service} 4h quota exceeded (#{usage}/#{limit} requests)"}
    else
      :ok
    end
  end

  defp check_service_4h(_, _, _), do: :ok

  defp check_service_week(key_id, service, %{"week" => limit}) when is_integer(limit) do
    usage = get_service_usage_in_window(key_id, service, LLMProxy.Config.usage_window_week_ms())

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

  def list_tokens(opts \\ %{}) do
    query = from(t in ProviderToken)
    query = if opts[:provider], do: where(query, [t], t.provider == ^opts.provider), else: query
    query = apply_sort(query, opts[:sort], opts[:dir], [:provider, :kind, :enabled])
    query = if query_has_order?(query), do: query, else: order_by(query, [:provider, :id])
    Repo.all(query)
  end

  def add_token(provider, kind, token, opts \\ %{}) do
    %ProviderToken{}
    |> ProviderToken.changeset(
      Map.merge(opts, %{
        provider: provider,
        kind: kind,
        token: token,
        added_at: DateTime.utc_now()
      })
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
    per_page = Map.get(opts, :per_page, Map.get(opts, :limit, 25))

    from(m in MessageLog,
      join: k in ApiKey,
      on: k.id == m.key_id,
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
    |> messages_filter_key(opts[:key_id])
    |> messages_search(opts[:search])
    |> messages_sort(opts[:sort], opts[:dir])
    |> limit(^(per_page + 1))
    |> messages_offset(opts[:offset])
    |> Repo.all()
  end

  defp messages_filter_key(query, nil), do: query
  defp messages_filter_key(query, key_id), do: where(query, [m], m.key_id == ^key_id)

  defp messages_search(query, nil), do: query
  defp messages_search(query, ""), do: query

  defp messages_search(query, term) do
    pattern = "%#{term}%"

    where(
      query,
      [m, k],
      fragment("lower(?) LIKE lower(?)", m.model, ^pattern) or
        fragment("lower(?) LIKE lower(?)", k.name, ^pattern) or
        fragment("lower(?) LIKE lower(?)", m.user_message, ^pattern)
    )
  end

  defp messages_sort(query, "model", dir),
    do: order_by(query, [m], [{^sort_dir(dir), m.model}])

  defp messages_sort(query, "key_name", dir),
    do: order_by(query, [m, k], [{^sort_dir(dir), k.name}])

  defp messages_sort(query, "route", dir),
    do: order_by(query, [m], [{^sort_dir(dir), m.route}])

  defp messages_sort(query, "timestamp", dir),
    do: order_by(query, [m], [{^sort_dir(dir), m.timestamp}])

  defp messages_sort(query, _, _),
    do: order_by(query, [m], desc: m.timestamp)

  defp messages_offset(query, nil), do: query
  defp messages_offset(query, offset), do: offset(query, ^offset)

  # --- Stats ---

  def get_stats do
    key_stats =
      from(k in ApiKey,
        select: %{
          count: count(k.id),
          input: coalesce(sum(k.input_tokens), 0),
          output: coalesce(sum(k.output_tokens), 0),
          cache_read: coalesce(sum(k.cache_read_tokens), 0),
          cache_write: coalesce(sum(k.cache_write_tokens), 0),
          spend: coalesce(sum(k.total_spend_usd), 0.0)
        }
      )
      |> Repo.one()

    request_count = from(u in UsageLog, select: count(u.id)) |> Repo.one()

    recent =
      from(u in UsageLog,
        order_by: [desc: u.timestamp],
        limit: 50,
        select: %{
          id: u.id,
          key_id: u.key_id,
          model: u.model,
          input_tokens: u.input_tokens,
          output_tokens: u.output_tokens,
          cache_read_tokens: u.cache_read_tokens,
          cache_write_tokens: u.cache_write_tokens,
          cost_usd: u.cost_usd,
          duration_ms: u.duration_ms,
          ttft_ms: u.ttft_ms,
          provider: u.provider,
          tags: u.tags,
          metadata: u.metadata,
          timestamp: u.timestamp
        }
      )
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
      total_spend_usd: key_stats.spend,
      recent_usage: recent,
      service_stats: service_stats
    }
  end

  # --- Traces ---

  def record_trace(attrs) do
    %Trace{}
    |> Trace.changeset(attrs)
    |> Repo.insert()
  end

  def get_traces(opts \\ %{}) do
    per_page = Map.get(opts, :per_page, 25)

    from(t in Trace,
      join: k in ApiKey,
      on: k.id == t.key_id,
      select: %{
        id: t.id,
        key_id: t.key_id,
        key_name: k.name,
        model: t.model,
        provider: t.provider,
        input_tokens: t.input_tokens,
        output_tokens: t.output_tokens,
        cost_usd: t.cost_usd,
        duration_ms: t.duration_ms,
        ttft_ms: t.ttft_ms,
        session_id: t.session_id,
        timestamp: t.timestamp
      }
    )
    |> traces_filter_key(opts[:key_id])
    |> traces_filter_session(opts[:session_id])
    |> traces_filter_model(opts[:model])
    |> traces_search(opts[:search])
    |> order_by([t], desc: t.timestamp)
    |> limit(^(per_page + 1))
    |> traces_offset(opts[:offset])
    |> Repo.all()
  end

  def get_trace(id) do
    Repo.get(Trace, id)
  end

  def record_trace_feedback(attrs) do
    attrs =
      attrs
      |> resolve_feedback_trace()
      |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.truncate(:second))

    %TraceFeedback{}
    |> TraceFeedback.changeset(attrs)
    |> Repo.insert()
  end

  def list_trace_feedback(trace_or_request_id) do
    TraceFeedback
    |> feedback_for(trace_or_request_id)
    |> order_by([f], desc: f.timestamp)
    |> Repo.all()
  end

  def get_trace_feedback(trace_id) when is_integer(trace_id) do
    from(f in TraceFeedback,
      where: f.trace_id == ^trace_id,
      order_by: [desc: f.timestamp]
    )
    |> Repo.all()
  end

  def find_trace_by_request_id(request_id) when is_binary(request_id) do
    Trace
    |> trace_request_id_query(request_id, SQL.supported_adapter!())
    |> order_by([t], desc: t.timestamp)
    |> limit(1)
    |> Repo.one()
  end

  defp resolve_feedback_trace(%{trace_id: trace_id} = attrs) when is_integer(trace_id) do
    attrs
    |> Map.put_new(
      :request_id,
      trace_request_id(Repo.get(Trace, trace_id)) || Integer.to_string(trace_id)
    )
  end

  defp resolve_feedback_trace(%{request_id: request_id} = attrs) when is_binary(request_id) do
    case find_trace_by_request_id(request_id) do
      %Trace{id: id} -> Map.put_new(attrs, :trace_id, id)
      nil -> attrs
    end
  end

  defp resolve_feedback_trace(attrs), do: attrs

  defp trace_request_id(%Trace{metadata: %{"trace_id" => request_id}}), do: request_id
  defp trace_request_id(_trace), do: nil

  defp trace_request_id_query(query, request_id, :sqlite) do
    where(query, [t], fragment("json_extract(?, '$.trace_id') = ?", t.metadata, ^request_id))
  end

  defp trace_request_id_query(query, request_id, :postgres) do
    where(query, [t], fragment("?->>'trace_id' = ?", t.metadata, ^request_id))
  end

  defp trace_request_id_query(query, request_id, :mysql) do
    where(
      query,
      [t],
      fragment("JSON_UNQUOTE(JSON_EXTRACT(?, '$.trace_id')) = ?", t.metadata, ^request_id)
    )
  end

  defp feedback_for(query, trace_id) when is_integer(trace_id),
    do: where(query, [f], f.trace_id == ^trace_id)

  defp feedback_for(query, request_id) when is_binary(request_id),
    do: where(query, [f], f.request_id == ^request_id)

  defp traces_filter_key(query, nil), do: query
  defp traces_filter_key(query, key_id), do: where(query, [t], t.key_id == ^key_id)

  defp traces_filter_session(query, nil), do: query
  defp traces_filter_session(query, sid), do: where(query, [t], t.session_id == ^sid)

  defp traces_filter_model(query, nil), do: query
  defp traces_filter_model(query, model), do: where(query, [t], t.model == ^model)

  defp traces_search(query, nil), do: query
  defp traces_search(query, ""), do: query

  defp traces_search(query, term) do
    pattern = "%#{term}%"

    where(
      query,
      [t, k],
      fragment("lower(?) LIKE lower(?)", k.name, ^pattern) or
        fragment("lower(?) LIKE lower(?)", t.model, ^pattern)
    )
  end

  defp traces_offset(query, nil), do: query
  defp traces_offset(query, offset), do: offset(query, ^offset)

  # --- Daily Stats ---

  def get_daily_stats(opts \\ %{}) do
    start_date = parse_date(opts[:start_date]) || Date.add(Date.utc_today(), -30)
    end_date = parse_date(opts[:end_date]) || Date.utc_today()
    start_dt = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(Date.add(end_date, 1), ~T[00:00:00], "Etc/UTC")

    UsageLog
    |> where([u], u.timestamp >= ^start_dt and u.timestamp < ^end_dt)
    |> daily_filter_key(opts[:key_id])
    |> select([u], %{
      id: u.id,
      timestamp: u.timestamp,
      input_tokens: u.input_tokens,
      output_tokens: u.output_tokens,
      cost_usd: u.cost_usd,
      duration_ms: u.duration_ms
    })
    |> Repo.all()
    |> Enum.group_by(&usage_date(&1.timestamp))
    |> Enum.map(&daily_entry/1)
    |> Enum.sort_by(& &1.date, Date)
  end

  defp daily_filter_key(query, nil), do: query
  defp daily_filter_key(query, key_id), do: where(query, [u], u.key_id == ^key_id)

  defp usage_date(%DateTime{} = timestamp), do: DateTime.to_date(timestamp)
  defp usage_date(%NaiveDateTime{} = timestamp), do: NaiveDateTime.to_date(timestamp)

  defp daily_entry({date, rows}) do
    request_count = length(rows)
    duration_sum = rows |> Enum.map(&(&1.duration_ms || 0)) |> Enum.sum()

    %{
      date: date,
      requests: request_count,
      input_tokens: Enum.sum(Enum.map(rows, &(&1.input_tokens || 0))),
      output_tokens: Enum.sum(Enum.map(rows, &(&1.output_tokens || 0))),
      cost_usd: Enum.sum(Enum.map(rows, &(&1.cost_usd || 0.0))),
      avg_duration_ms: if(request_count > 0, do: duration_sum / request_count, else: nil)
    }
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  # --- Helpers ---

  defp apply_sort(query, sort, dir, allowed_fields) do
    fields = Map.new(allowed_fields, &{Atom.to_string(&1), &1})

    case Map.fetch(fields, sort) do
      {:ok, field} -> order_by(query, [{^sort_dir(dir), ^field}])
      :error -> query
    end
  end

  defp sort_dir("desc"), do: :desc
  defp sort_dir(_), do: :asc

  defp query_has_order?(%Ecto.Query{order_bys: [_ | _]}), do: true
  defp query_has_order?(_), do: false

  defp hash_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end

  defp generate_uuid, do: Ecto.UUID.generate()
end
