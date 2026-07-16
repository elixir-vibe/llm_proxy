defmodule LLMProxy.Admin.Resources.ProviderToken do
  @moduledoc "Admin resource for upstream provider tokens."

  use Incant.Resource,
    schema: LLMProxy.Schemas.ProviderToken,
    title: "Provider Tokens"

  table density: :compact do
    column(:provider, link: true, priority: :primary)
    column(:kind, priority: :secondary)
    column(:label, priority: :primary)
    column(:enabled, as: :boolean, priority: :primary)
    column(:proxy, priority: :tertiary)
    column(:added_at, format: :datetime, priority: :tertiary)

    filter(:provider, :text)
    filter(:kind, :select, options: ["api-key", "oauth"])
    filter(:enabled, :boolean)

    action(:disable, confirm: true, callback: {__MODULE__, :disable})
    action(:enable, callback: {__MODULE__, :enable})
    action(:remove, confirm: true, destructive: true, callback: {__MODULE__, :remove})

    actions do
      page(:codex_oauth_start,
        label: "Start Codex OAuth",
        callback: {LLMProxy.Admin.CodexOAuth, :start}
      )

      page(:codex_oauth_complete,
        label: "Complete Codex OAuth",
        callback: {LLMProxy.Admin.CodexOAuth, :complete}
      )
    end
  end

  def index(params, _context), do: LLMProxy.Storage.list_tokens(params)

  def disable(%{id: id}, _assigns), do: set_enabled(id, false)
  def enable(%{id: id}, _assigns), do: set_enabled(id, true)

  def remove(%{id: id}, _assigns) do
    case LLMProxy.Storage.remove_token(id) do
      {:ok, _token} -> {:ok, Incant.ActionResult.refresh()}
      {:error, :not_found} -> {:error, "Provider token not found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp set_enabled(id, enabled) do
    case LLMProxy.Storage.set_token_enabled(id, enabled) do
      {:ok, _token} -> {:ok, Incant.ActionResult.refresh()}
      {:error, :not_found} -> {:error, "Provider token not found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
