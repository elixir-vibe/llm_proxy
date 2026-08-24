if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Resources.ApiKey do
    @moduledoc "Admin resource for LLMProxy API keys."

    alias LLMProxy.Admin.Resources.APIKey.CreateInput

    use Incant.Resource,
      schema: LLMProxy.Schemas.ApiKey,
      repo: LLMProxy.Storage.Repo,
      title: "API Keys"

    table density: :compact, default_sort: [name: :asc] do
      column(:name, link: true, priority: :primary)

      column(:enabled,
        as: :boolean,
        true_label: "Enabled",
        false_label: "Disabled",
        priority: :primary
      )

      column(:total_spend_usd, label: "Spend", format: :money, priority: :primary)
      column(:input_tokens, label: "Input tokens", format: :number, priority: :secondary)
      column(:output_tokens, label: "Output tokens", format: :number, priority: :secondary)
      column(:cache_read_tokens, label: "Cache read", format: :number, priority: :tertiary)

      column(:trace_requests,
        label: "Tracing",
        as: :boolean,
        true_label: "Enabled",
        false_label: "Disabled",
        priority: :secondary
      )

      filter(:name, :text)
      filter(:enabled, :boolean)
      filter(:trace_requests, :boolean)

      actions do
        page(:create,
          label: "Create API key",
          confirm: "Create a new API key?",
          callback: :create
        )
      end

      action(:delete, confirm: true, destructive: true, callback: :delete)

      action(:disable,
        available_if: [enabled: true],
        confirm: "Disable this API key?",
        callback: :disable
      )

      action(:enable, available_if: [enabled: false], callback: :enable)

      search([:name])
    end

    def create(_params, assigns) do
      with {:ok, command} <- CreateInput.from_assigns(assigns),
           {:ok, key, raw_key} <-
             LLMProxy.Storage.create_key(command.name, %{trace_requests: command.trace_requests}) do
        {:ok,
         Incant.ActionResult.job("api_key:#{key.id}",
           label: "Created #{command.name}",
           meta: %{id: key.id, name: key.name, token: raw_key}
         )}
      else
        {:error, message} when is_binary(message) -> {:error, message}
        {:error, changeset} -> {:error, inspect(changeset.errors)}
      end
    end

    def delete(%{id: id}, _assigns) do
      case LLMProxy.Storage.delete_key(id) do
        {:ok, _key} -> {:ok, Incant.ActionResult.refresh()}
        {:error, :not_found} -> {:error, "API key not found"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end

    def disable(%{id: id}, _assigns), do: set_enabled(id, false)
    def enable(%{id: id}, _assigns), do: set_enabled(id, true)

    defp set_enabled(id, enabled) do
      case LLMProxy.Storage.set_key_enabled(id, enabled) do
        {:ok, _key} -> {:ok, Incant.ActionResult.refresh()}
        {:error, :not_found} -> {:error, "API key not found"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end
end
