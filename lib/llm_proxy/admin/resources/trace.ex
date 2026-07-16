defmodule LLMProxy.Admin.Resources.Trace do
  @moduledoc "Admin resource for recorded LLM traces."

  alias LLMProxy.Admin.Query

  use Incant.Resource,
    schema: LLMProxy.Schemas.Trace,
    title: "Traces"

  table density: :compact do
    column(:timestamp, link: true, format: :datetime, priority: :primary)
    column(:key_id, format: :id, priority: :tertiary)
    column(:model, priority: :primary)
    column(:provider, priority: :secondary)
    column(:input_tokens, label: "Input", format: :number, priority: :secondary)
    column(:output_tokens, label: "Output", format: :number, priority: :secondary)
    column(:cost_usd, label: "Cost", format: :money, priority: :secondary)
    column(:duration_ms, label: "Latency", format: :duration_ms, priority: :tertiary)
    column(:ttft_ms, label: "TTFT", format: :duration_ms, priority: :tertiary)

    filter(:model, :combobox, options_from: :model)
    filter(:provider, :select, options: ["anthropic", "openai", "openai-codex", "openrouter"])
    filter(:timestamp, :date_range)

    row_detail(:payload, label: "Request/response")

    search([:model, :provider])
  end

  def index(params, _context) do
    params
    |> Query.options()
    |> LLMProxy.Storage.page_traces()
    |> Query.result()
  end
end
