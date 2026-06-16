defmodule LLMProxy.Admin.Resources.ApiKey do
  @moduledoc "Admin resource for LLMProxy API keys."

  use Incant.Resource,
    schema: LLMProxy.Schemas.ApiKey,
    title: "API Keys"

  index(&__MODULE__.rows/1)

  table density: :compact do
    column(:name, link: true)
    column(:total_spend_usd, label: "Spend", format: :money)
    column(:input_tokens, label: "Input tokens", format: :number)
    column(:output_tokens, label: "Output tokens", format: :number)
    column(:cache_read_tokens, label: "Cache read", format: :number)
    column(:trace_requests, label: "Trace", as: :boolean)

    filter(:name, :text)
    filter(:trace_requests, :boolean)

    action(:show_usage)
    action(:rotate, confirm: true)
    action(:delete, confirm: true, destructive: true)
  end

  def rows(params), do: LLMProxy.Storage.list_keys(params)
end
