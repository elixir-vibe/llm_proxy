defmodule LLMProxy.ProviderUsage.Snapshot do
  @moduledoc "Cached, redacted usage state for one provider-token record."

  alias LLMProxy.ProviderUsage.{Result, Window}

  @enforce_keys [:token_id, :provider_label, :account_label, :availability, :state]
  defstruct [
    :token_id,
    :provider_label,
    :account_label,
    :plan,
    :reset_credits_available,
    :reset_credit_expires_at,
    :availability,
    :state,
    :refreshed_at,
    :attempted_at,
    :error,
    windows: []
  ]

  @type state :: :fresh | :refreshing | :stale | :error | :disabled
  @type t :: %__MODULE__{
          token_id: integer(),
          provider_label: String.t(),
          account_label: String.t(),
          plan: String.t() | nil,
          reset_credits_available: non_neg_integer() | nil,
          reset_credit_expires_at: DateTime.t() | nil,
          availability: Result.availability(),
          state: state(),
          windows: [Window.t()],
          refreshed_at: DateTime.t() | nil,
          attempted_at: DateTime.t() | nil,
          error: String.t() | nil
        }
end
