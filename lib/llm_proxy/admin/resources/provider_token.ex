defmodule LLMProxy.Admin.Resources.ProviderToken do
  @moduledoc "Admin resource for upstream provider tokens."

  use Incant.Resource,
    schema: LLMProxy.Schemas.ProviderToken,
    repo: LLMProxy.Storage.Repo,
    title: "Provider Tokens"

  table density: :compact, default_sort: [provider: :asc] do
    column(:provider, link: true, priority: :primary)
    column(:kind, priority: :secondary)
    column(:label, priority: :primary)

    column(:enabled,
      as: :boolean,
      true_label: "Enabled",
      false_label: "Disabled",
      priority: :primary
    )

    column(:proxy, priority: :tertiary)
    column(:added_at, format: :datetime, priority: :tertiary)

    filter(:provider, :select,
      options: %{
        "anthropic" => "Anthropic",
        "openai" => "OpenAI",
        "openai-codex" => "OpenAI Codex",
        "openrouter" => "OpenRouter"
      }
    )

    filter(:kind, :select, options: %{"api-key" => "API key", "oauth" => "OAuth"})
    filter(:enabled, :boolean)

    action(:disable,
      available_if: [enabled: true],
      confirm: "Disable this provider token?",
      callback: :disable
    )

    action(:enable,
      available_if: [enabled: false],
      callback: :enable
    )

    action(:remove, confirm: true, destructive: true, callback: :remove)

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

    search([:provider, :label])
  end

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
