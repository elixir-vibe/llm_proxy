if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Dashboards.ProviderUsage do
    @moduledoc "Live, redacted provider usage-window dashboard."

    use Incant.Dashboard

    title("Provider Usage")

    grid columns: 12 do
      stat(:accounts, span: 3, label: "Tracked accounts", query: &__MODULE__.accounts/2)

      stat(:available,
        span: 3,
        label: "Available now",
        query: &__MODULE__.available/2
      )

      stat(:exhausted,
        span: 3,
        label: "Quota exhausted",
        query: &__MODULE__.exhausted/2
      )

      stat(:attention,
        span: 3,
        label: "Needs attention",
        query: &__MODULE__.attention/2
      )

      table :usage_windows,
        span: 12,
        label: "Account quota windows",
        preview_rows: 50,
        query: &__MODULE__.usage_windows/2 do
        column(:account, label: "Account", priority: :primary)
        column(:provider, label: "Provider", priority: :secondary)
        column(:window, label: "Window", priority: :primary)

        column(:remaining_ratio,
          label: "Remaining",
          format: :percent,
          priority: :primary
        )

        column(:resets_in, label: "Resets in", priority: :primary)
        column(:availability, label: "Availability", priority: :primary)
        column(:reset_credits_available, label: "Reset credits", priority: :secondary)

        column(:reset_credit_expires_in,
          label: "Credit expires in",
          priority: :secondary
        )
      end
    end

    def accounts(_variables, _context), do: LLMProxy.ProviderUsage.account_count()
    def available(_variables, _context), do: LLMProxy.ProviderUsage.available_count()
    def exhausted(_variables, _context), do: LLMProxy.ProviderUsage.exhausted_count()
    def attention(_variables, _context), do: LLMProxy.ProviderUsage.attention_count()
    def usage_windows(_variables, _context), do: LLMProxy.ProviderUsage.rows()
  end
end
