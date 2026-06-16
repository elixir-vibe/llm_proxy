defmodule LLMProxy.Admin.Resources.Trace do
  @moduledoc "Admin resource for recorded LLM traces."

  use Incant.Resource,
    schema: LLMProxy.Schemas.Trace,
    title: "Traces"

  index(&__MODULE__.rows/1)

  table density: :compact do
    column(:timestamp, link: true, format: :datetime)
    column(:key_id)
    column(:model)
    column(:provider)
    column(:input_tokens, label: "Input", format: :number)
    column(:output_tokens, label: "Output", format: :number)
    column(:cost_usd, label: "Cost", format: :money)
    column(:duration_ms, label: "Latency", format: :duration_ms)
    column(:ttft_ms, label: "TTFT", format: :duration_ms)

    filter(:model, :text)
    filter(:provider, :text)
    filter(:timestamp, :date_range)

    row_detail(:payload, label: "Request/response")
    action(:open_feedback)
  end

  def rows(params), do: LLMProxy.Storage.get_traces(params)
end
