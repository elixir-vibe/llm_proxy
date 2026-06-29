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

    action(:disable, confirm: true, callback: {__MODULE__, :disable})
    action(:enable, callback: {__MODULE__, :enable})
    action(:remove, confirm: true, destructive: true, callback: {__MODULE__, :remove})
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
