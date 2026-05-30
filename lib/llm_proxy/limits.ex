defmodule LLMProxy.Limits do
  @moduledoc false

  import Ecto.Query

  alias LLMProxy.Repo
  alias LLMProxy.Schemas.UsageLog

  @metrics %{
    "cost_usd" => :cost_usd,
    "input_tokens" => :input_tokens,
    "output_tokens" => :output_tokens,
    "cache_read_tokens" => :cache_read_tokens,
    "cache_write_tokens" => :cache_write_tokens,
    "requests" => :requests
  }

  @windows %{
    "1m" => 60_000,
    "1h" => 60 * 60_000,
    "4h" => 4 * 60 * 60_000,
    "24h" => 24 * 60 * 60_000,
    "7d" => 7 * 24 * 60 * 60_000,
    "week" => 7 * 24 * 60 * 60_000,
    "30d" => 30 * 24 * 60 * 60_000
  }

  @spec check(map()) :: :ok | {:error, String.t()}
  def check(%{budget_limits: limits, id: key_id}) do
    limits
    |> normalize_limits()
    |> Enum.reduce_while(:ok, fn limit, :ok ->
      case check_limit(key_id, limit) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def check(_key), do: :ok

  @spec valid?(term()) :: boolean()
  def valid?(nil), do: true
  def valid?(%{"limits" => limits}) when is_list(limits), do: Enum.all?(limits, &valid_limit?/1)
  def valid?(%{limits: limits}) when is_list(limits), do: Enum.all?(limits, &valid_limit?/1)
  def valid?(_limits), do: false

  defp normalize_limits(nil), do: []
  defp normalize_limits(%{"limits" => limits}) when is_list(limits), do: limits
  defp normalize_limits(%{limits: limits}) when is_list(limits), do: limits
  defp normalize_limits(_limits), do: []

  defp valid_limit?(%{} = limit) do
    metric = get(limit, :metric, "metric")
    window = get(limit, :window, "window")
    max = get(limit, :max, "max")

    is_binary(metric) and Map.has_key?(@metrics, metric) and
      is_binary(window) and Map.has_key?(@windows, window) and number?(max) and max >= 0
  end

  defp valid_limit?(_limit), do: false

  defp check_limit(key_id, limit) do
    metric = get(limit, :metric, "metric")
    window = get(limit, :window, "window")
    max = get(limit, :max, "max")
    usage = usage(key_id, Map.fetch!(@metrics, metric), Map.fetch!(@windows, window))

    if usage >= max do
      {:error,
       "#{metric} limit exceeded for #{window} (#{format_usage(usage)}/#{format_usage(max)})"}
    else
      :ok
    end
  end

  defp usage(key_id, metric, window_ms) do
    since = DateTime.add(DateTime.utc_now(), -window_ms, :millisecond)

    UsageLog
    |> where([u], u.key_id == ^key_id and u.timestamp >= ^since)
    |> select_metric(metric)
    |> Repo.one()
    |> case do
      nil -> 0
      value -> value
    end
  end

  defp select_metric(query, :requests), do: select(query, [u], count(u.id))
  defp select_metric(query, :cost_usd), do: select(query, [u], coalesce(sum(u.cost_usd), 0.0))

  defp select_metric(query, :input_tokens),
    do: select(query, [u], coalesce(sum(u.input_tokens), 0))

  defp select_metric(query, :output_tokens),
    do: select(query, [u], coalesce(sum(u.output_tokens), 0))

  defp select_metric(query, :cache_read_tokens),
    do: select(query, [u], coalesce(sum(u.cache_read_tokens), 0))

  defp select_metric(query, :cache_write_tokens),
    do: select(query, [u], coalesce(sum(u.cache_write_tokens), 0))

  defp get(map, atom_key, string_key), do: Map.get(map, atom_key, Map.get(map, string_key))

  defp number?(value), do: is_integer(value) or is_float(value)

  defp format_usage(value) when is_float(value), do: Float.round(value, 6)
  defp format_usage(value), do: value
end
