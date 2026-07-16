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
      format: :number,
      query: &__MODULE__.input_tokens/2
    )

    stat(:output_tokens,
      span: 2,
      label: "Output tokens",
      format: :number,
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
      column(:duration_ms, label: "Duration", format: :number, priority: :tertiary)
      column(:ttft_ms, label: "TTFT", format: :number, priority: :tertiary)
      column(:key_id, label: "Key", priority: :tertiary)
    end

    table :service_usage, span: 3, label: "Service usage", query: &__MODULE__.service_usage/2 do
      column(:service, label: "Service", priority: :primary)
      column(:count, label: "Count", format: :number, priority: :primary)
    end
  end

  def total_keys(_variables, _context), do: stats().total_keys
  def total_requests(_variables, _context), do: stats().total_requests
  def total_spend(_variables, _context), do: stats().total_spend_usd
  def input_tokens(_variables, _context), do: stats().total_input_tokens
  def output_tokens(_variables, _context), do: stats().total_output_tokens

  def recent_usage(_variables, _context) do
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
      rows: stats().recent_usage
    }
  end

  def service_usage(_variables, _context) do
    %{
      columns: [:service, :count],
      rows: stats().service_stats
    }
  end

  defp stats, do: LLMProxy.Storage.get_stats()
end
