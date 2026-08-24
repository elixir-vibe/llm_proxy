defmodule LLMProxy.ProviderUsage.Result do
  @moduledoc "Normalized provider result without credential data."

  alias LLMProxy.ProviderUsage.Window

  @enforce_keys [:availability, :windows]
  defstruct [
    :plan,
    :expires_at,
    :reset_credits_available,
    :reset_credit_expires_at,
    availability: :unknown,
    windows: []
  ]

  @type availability :: :available | :limited | :unavailable | :unknown
  @type t :: %__MODULE__{
          availability: availability(),
          windows: [Window.t()],
          plan: String.t() | nil,
          expires_at: DateTime.t() | nil,
          reset_credits_available: non_neg_integer() | nil,
          reset_credit_expires_at: DateTime.t() | nil
        }
end
