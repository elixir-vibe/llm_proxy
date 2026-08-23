if Code.ensure_loaded?(Incant) do
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

      column(:proxy, priority: :tertiary, sensitive: true)
      column(:added_at, format: :datetime, priority: :tertiary)

      filter(:provider, :text)

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

      action(:refresh_usage,
        available_if: [enabled: true],
        callback: :refresh_usage
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

        page(:refresh_all_usage,
          label: "Refresh provider usage",
          callback: :refresh_all_usage
        )
      end

      search([:provider, :label])
    end

    def disable(%{id: id}, _assigns), do: set_enabled(id, false)
    def enable(%{id: id}, _assigns), do: set_enabled(id, true)

    def refresh_usage(%{id: id}, _assigns) do
      case LLMProxy.ProviderUsage.refresh_account(id) do
        {:ok, _status} -> {:ok, Incant.ActionResult.refresh()}
        {:error, :unsupported} -> {:error, "Usage tracking is not supported for this token"}
        {:error, :unavailable} -> {:error, "Provider usage tracker is unavailable"}
      end
    end

    def refresh_all_usage(_params, _assigns) do
      case LLMProxy.ProviderUsage.refresh_all() do
        {:ok, _status} -> {:ok, Incant.ActionResult.refresh()}
        {:error, :unavailable} -> {:error, "Provider usage tracker is unavailable"}
      end
    end

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
end
