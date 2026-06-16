defmodule LLMProxy.Admin.Resources.ProviderToken do
  @moduledoc "Admin resource for upstream provider tokens."

  use Incant.Resource,
    schema: LLMProxy.Schemas.ProviderToken,
    title: "Provider Tokens"

  table density: :compact do
    column(:provider, link: true)
    column(:kind)
    column(:label)
    column(:enabled, as: :boolean)
    column(:proxy)
    column(:added_at, format: :datetime)

    filter(:provider, :text)
    filter(:kind, :select, options: ["api-key", "oauth"])
    filter(:enabled, :boolean)

    action(:disable, confirm: true)
    action(:enable)
    action(:remove, confirm: true, destructive: true)
  end

  def index(params, _context), do: LLMProxy.Storage.list_tokens(params)
end
