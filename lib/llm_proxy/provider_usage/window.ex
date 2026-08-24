defmodule LLMProxy.ProviderUsage.Window do
  @moduledoc "One authoritative upstream usage window."

  @enforce_keys [:label, :used_percent, :remaining_percent]
  defstruct [:label, :used_percent, :remaining_percent, :resets_at, :duration_seconds]

  @type t :: %__MODULE__{
          label: String.t(),
          used_percent: number(),
          remaining_percent: number(),
          resets_at: DateTime.t() | nil,
          duration_seconds: non_neg_integer() | nil
        }
end
