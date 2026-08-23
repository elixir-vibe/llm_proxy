if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Dashboards.ProviderUsage do
    @moduledoc "Live, redacted provider usage-window dashboard."

    use Incant.Dashboard

    title("Provider Usage")

    grid columns: 12 do
      stat(:accounts, span: 4, label: "Tracked accounts", query: &__MODULE__.accounts/2)

      stat(:available,
        span: 4,
        label: "Available accounts",
        query: &__MODULE__.available/2
      )

      stat(:attention,
        span: 4,
        label: "Need attention",
        query: &__MODULE__.attention/2
      )

      table :usage_windows,
        span: 12,
        label: "Live usage windows",
        preview_rows: 50,
        query: &__MODULE__.usage_windows/2 do
        column(:provider, label: "Provider", priority: :primary)
        column(:account, label: "Account", priority: :primary)
        column(:window, label: "Window", priority: :primary)
        column(:used_percent, label: "Used %", format: :number, priority: :primary)

        column(:remaining_percent,
          label: "Remaining %",
          format: :number,
          priority: :secondary
        )

        column(:resets_at, label: "Resets or expires", format: :datetime, priority: :secondary)
        column(:availability, label: "Availability", priority: :primary)
        column(:state, label: "Refresh state", priority: :secondary)
        column(:last_refresh, label: "Last refresh", format: :relative, priority: :secondary)
        column(:last_attempt, label: "Last attempt", format: :relative, priority: :tertiary)
        column(:error, label: "Error", priority: :secondary)
      end
    end

    def accounts(_variables, _context), do: LLMProxy.ProviderUsage.account_count()
    def available(_variables, _context), do: LLMProxy.ProviderUsage.available_count()
    def attention(_variables, _context), do: LLMProxy.ProviderUsage.attention_count()
    def usage_windows(_variables, _context), do: LLMProxy.ProviderUsage.rows()
  end
end
