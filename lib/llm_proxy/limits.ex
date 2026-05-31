defmodule LLMProxy.Limits do
  @moduledoc false

  import Ecto.Query

  alias LLMProxy.Limit
  alias LLMProxy.Repo
  alias LLMProxy.Schemas.UsageLog

  @metric_aliases %{
    "cost_usd" => :cost_usd,
    "input_tokens" => :input_tokens,
    "output_tokens" => :output_tokens,
    "cache_read_tokens" => :cache_read_tokens,
    "cache_write_tokens" => :cache_write_tokens,
    "requests" => :requests
  }

  @window_aliases %{
    "1m" => :minute,
    "minute" => :minute,
    "1h" => :hour,
    "hour" => :hour,
    "4h" => :four_hours,
    "four_hours" => :four_hours,
    "24h" => :day,
    "day" => :day,
    "7d" => :week,
    "week" => :week,
    "30d" => :month,
    "month" => :month
  }

  @window_ms %{
    minute: :timer.minutes(1),
    hour: :timer.hours(1),
    four_hours: :timer.hours(4),
    day: :timer.hours(24),
    week: :timer.hours(24 * 7),
    month: :timer.hours(24 * 30)
  }

  @spec check(map()) :: :ok | {:error, String.t()}
  def check(%{budget_limits: limits, id: key_id}) do
    limits
    |> normalize_all()
    |> Enum.reduce_while(:ok, fn limit, :ok ->
      case check_limit(key_id, limit) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def check(_key), do: :ok

  @spec normalize(term()) :: {:ok, [Limit.t()]} | {:error, String.t()}
  def normalize(nil), do: {:ok, []}

  def normalize(limits) when is_list(limits) do
    limits
    |> Enum.reduce_while({:ok, []}, fn limit, {:ok, acc} ->
      case normalize_limit(limit) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  def normalize(_limits), do: {:error, "must be a list of limits"}

  @spec valid?(term()) :: boolean()
  def valid?(limits), do: match?({:ok, _limits}, normalize(limits))

  defp normalize_all(limits) do
    case normalize(limits) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> []
    end
  end

  defp normalize_limit(%Limit{} = limit), do: {:ok, limit}

  defp normalize_limit(%{} = limit) do
    with {:ok, metric} <- normalize_metric(get(limit, :metric, "metric")),
         {:ok, window} <- normalize_window(get(limit, :window, "window")),
         {:ok, max} <- normalize_max(get(limit, :max, "max")) do
      {:ok, Limit.new(metric, window, max)}
    end
  end

  defp normalize_limit(_limit), do: {:error, "limit must be a map"}

  defp normalize_metric(metric) when is_atom(metric) do
    if metric in Limit.metrics(), do: {:ok, metric}, else: {:error, "invalid metric"}
  end

  defp normalize_metric(metric) when is_binary(metric) do
    case Map.fetch(@metric_aliases, metric) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, "invalid metric"}
    end
  end

  defp normalize_metric(_metric), do: {:error, "invalid metric"}

  defp normalize_window(window) when is_atom(window) do
    if window in Limit.windows(), do: {:ok, window}, else: {:error, "invalid window"}
  end

  defp normalize_window(window) when is_binary(window) do
    case Map.fetch(@window_aliases, window) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, "invalid window"}
    end
  end

  defp normalize_window(_window), do: {:error, "invalid window"}

  defp normalize_max(max) when is_number(max) and max >= 0, do: {:ok, max}
  defp normalize_max(_max), do: {:error, "invalid max"}

  defp check_limit(key_id, %Limit{} = limit) do
    usage = usage(key_id, limit.metric, Map.fetch!(@window_ms, limit.window))

    if usage >= limit.max do
      {:error,
       "#{limit.metric} limit exceeded for #{limit.window} (#{format_usage(usage)}/#{format_usage(limit.max)})"}
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

  defp format_usage(value) when is_float(value), do: Float.round(value, 6)
  defp format_usage(value), do: value
end
