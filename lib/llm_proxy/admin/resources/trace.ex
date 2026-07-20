defmodule LLMProxy.Admin.Resources.Trace do
  @moduledoc "Admin resource for recorded LLM traces."

  use Incant.Resource,
    schema: LLMProxy.Schemas.Trace,
    repo: LLMProxy.Storage.Repo,
    title: "Traces"

  table density: :compact,
        default_sort: [timestamp: :desc],
        empty_state: "No traces recorded yet. Enable tracing on an API key to start collecting request traces." do
    column(:timestamp, link: true, format: :datetime, priority: :primary)
    column(:key_id, format: :id, priority: :tertiary)
    column(:model, priority: :primary)
    column(:provider, priority: :secondary)
    column(:input_tokens, label: "Input", format: :number, priority: :secondary)
    column(:output_tokens, label: "Output", format: :number, priority: :secondary)
    column(:cost_usd, label: "Cost", format: :money, priority: :secondary)
    column(:duration_ms, label: "Latency", format: :duration_ms, priority: :tertiary)
    column(:ttft_ms, label: "TTFT", format: :duration_ms, priority: :tertiary)

    filter(:model, :combobox, options: :distinct)

    filter(:provider, :select,
      options: %{
        "anthropic" => "Anthropic",
        "openai" => "OpenAI",
        "openai-codex" => "OpenAI Codex",
        "openrouter" => "OpenRouter"
      }
    )

    filter(:timestamp, :date_range)

    row_detail(:payload, label: "Request/response")

    search([:model, :provider])
  end
end
