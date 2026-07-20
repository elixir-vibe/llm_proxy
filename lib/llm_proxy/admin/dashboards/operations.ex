defmodule LLMProxy.Admin.Dashboards.Operations do
  @moduledoc "Operations dashboard for LLMProxy usage, spend, and token activity."

  use Incant.Dashboard

  title("Operations")

  variables do
    var(:range, :date_range, default: "24h")
  end

  grid columns: 10 do
    stat(:api_keys, span: 2, label: "API Keys", query: &__MODULE__.total_keys/2)
    stat(:requests, span: 2, label: "Requests", query: &__MODULE__.total_requests/2)
    stat(:spend, span: 2, label: "Spend", format: :money, query: &__MODULE__.total_spend/2)

    stat(:input_tokens,
      span: 2,
      label: "Input tokens",
      format: :compact_number,
      query: &__MODULE__.input_tokens/2
    )

    stat(:output_tokens,
      span: 2,
      label: "Output tokens",
      format: :compact_number,
      query: &__MODULE__.output_tokens/2
    )

    table :recent_usage,
      span: 7,
      label: "Recent requests",
      preview_rows: 10,
      query: &__MODULE__.recent_usage/2 do
      column(:timestamp, label: "Timestamp", format: :datetime, priority: :primary)
      column(:provider, label: "Provider", priority: :secondary)
      column(:model, label: "Model", priority: :primary)
      column(:input_tokens, label: "Input tokens", format: :number, priority: :secondary)
      column(:output_tokens, label: "Output tokens", format: :number, priority: :tertiary)
      column(:cost_usd, label: "Cost", format: :money, priority: :secondary)
      column(:duration_ms, label: "Duration", format: :duration_ms, priority: :tertiary)
      column(:ttft_ms, label: "TTFT", format: :duration_ms, priority: :tertiary)
      column(:key_id, label: "Key", format: :id, priority: :tertiary)
    end

    table :service_usage, span: 3, label: "Service usage", query: &__MODULE__.service_usage/2 do
      column(:service, label: "Service", priority: :primary)
      column(:count, label: "Count", format: :number, priority: :primary)
    end
  end

  def total_keys(variables, _context), do: stats(variables).total_keys
  def total_requests(variables, _context), do: stats(variables).total_requests
  def total_spend(variables, _context), do: stats(variables).total_spend_usd
  def input_tokens(variables, _context), do: stats(variables).total_input_tokens
  def output_tokens(variables, _context), do: stats(variables).total_output_tokens

  def recent_usage(variables, _context) do
    %{
      columns: [
        :timestamp,
        :provider,
        :model,
        :input_tokens,
        :output_tokens,
        :cost_usd,
        :duration_ms,
        :ttft_ms,
        :key_id
      ],
      rows: stats(variables).recent_usage
    }
  end

  def service_usage(variables, _context) do
    %{
      columns: [:service, :count],
      rows: stats(variables).service_stats
    }
  end

  defp stats(variables), do: LLMProxy.Storage.get_stats(stats_window(variables))

  defp stats_window(variables) do
    variables
    |> Map.get("range", Map.get(variables, :range, "24h"))
    |> range_window(DateTime.utc_now())
  end

  defp range_window("1h", now), do: %{from: DateTime.add(now, -3_600, :second)}
  defp range_window("24h", now), do: %{from: DateTime.add(now, -86_400, :second)}
  defp range_window("7d", now), do: %{from: DateTime.add(now, -604_800, :second)}
  defp range_window("30d", now), do: %{from: DateTime.add(now, -2_592_000, :second)}

  defp range_window(%{} = range, now) do
    with {:ok, from_date} <- date_value(Map.get(range, "from", Map.get(range, :from))),
         {:ok, to_date} <- date_value(Map.get(range, "to", Map.get(range, :to))) do
      %{
        from: DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC"),
        to: DateTime.new!(Date.add(to_date, 1), ~T[00:00:00], "Etc/UTC")
      }
    else
      _error -> range_window("24h", now)
    end
  end

  defp range_window(_range, now), do: range_window("24h", now)

  defp date_value(%Date{} = date), do: {:ok, date}
  defp date_value(value) when is_binary(value), do: Date.from_iso8601(value)
  defp date_value(_value), do: :error
end
