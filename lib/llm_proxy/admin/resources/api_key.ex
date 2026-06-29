defmodule LLMProxy.Admin.Resources.ApiKey do
  @moduledoc "Admin resource for LLMProxy API keys."

  use Incant.Resource,
    schema: LLMProxy.Schemas.ApiKey,
    title: "API Keys"

  table density: :compact do
    column(:name, link: true)
    column(:total_spend_usd, label: "Spend", format: :money)
    column(:input_tokens, label: "Input tokens", format: :number)
    column(:output_tokens, label: "Output tokens", format: :number)
    column(:cache_read_tokens, label: "Cache read", format: :number)
    column(:trace_requests, label: "Trace", as: :boolean)

    filter(:name, :text)
    filter(:trace_requests, :boolean)

    action(:delete, confirm: true, destructive: true, callback: {__MODULE__, :delete})
  end

  def index(params, _context), do: LLMProxy.Storage.list_keys(params)

  def delete(%{id: id}, _assigns) do
    case LLMProxy.Storage.delete_key(id) do
      {:ok, _key} -> {:ok, Incant.ActionResult.refresh()}
      {:error, :not_found} -> {:error, "API key not found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
