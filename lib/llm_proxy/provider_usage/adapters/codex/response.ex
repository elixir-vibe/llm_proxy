defmodule LLMProxy.ProviderUsage.Adapters.Codex.Response do
  @moduledoc false

  defmodule Shape do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct rate_limit: :missing, rate_limits: :missing

    @type t :: %__MODULE__{rate_limit: term(), rate_limits: term()}

    codec(:rate_limits, as: "rateLimits")
  end

  defmodule ReachedType do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:type]

    @type t :: %__MODULE__{type: String.t()}
  end

  defmodule SpendControl do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:reached]

    @type t :: %__MODULE__{reached: boolean()}
  end

  defmodule ResetCredit do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:status, :granted_at, :expires_at]

    @type t :: %__MODULE__{
            status: String.t(),
            granted_at: String.t() | nil,
            expires_at: String.t() | nil
          }
  end

  defmodule ResetCredits do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:available_count, :applicable_available_count, credits: []]

    @type t :: %__MODULE__{
            available_count: non_neg_integer() | nil,
            applicable_available_count: non_neg_integer() | nil,
            credits: [ResetCredit.t()]
          }
  end

  defmodule CurrentWindow do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [
      :used_percent,
      :limit_window_seconds,
      :window_minutes,
      :reset_at,
      :resets_at
    ]

    @type t :: %__MODULE__{
            used_percent: number(),
            limit_window_seconds: number() | nil,
            window_minutes: number() | nil,
            reset_at: integer() | nil,
            resets_at: integer() | nil
          }
  end

  defmodule CurrentLimits do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:allowed, :limit_reached, :primary_window, :secondary_window]

    @type t :: %__MODULE__{
            allowed: boolean() | nil,
            limit_reached: boolean() | nil,
            primary_window: CurrentWindow.t() | nil,
            secondary_window: CurrentWindow.t() | nil
          }
  end

  defmodule Current do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [
      :plan_type,
      :rate_limit,
      :rate_limit_reached_type,
      :rate_limit_reset_credits,
      :spend_control,
      :spend_control_reached
    ]

    @type t :: %__MODULE__{
            plan_type: String.t() | nil,
            rate_limit: CurrentLimits.t(),
            rate_limit_reached_type: ReachedType.t() | nil,
            rate_limit_reset_credits: ResetCredits.t() | nil,
            spend_control: SpendControl.t() | nil,
            spend_control_reached: boolean() | nil
          }
  end

  defmodule LegacyWindow do
    @moduledoc false

    use JSONCodec, case: :camel, strict: true, fast_path: :json

    defstruct [:used_percent, :window_duration_mins, :resets_at]

    @type t :: %__MODULE__{
            used_percent: number(),
            window_duration_mins: number() | nil,
            resets_at: integer() | nil
          }

    codec(:resets_at, cast: :integer_timestamp)

    def integer_timestamp(nil), do: nil
    def integer_timestamp(value) when is_integer(value), do: value

    def integer_timestamp(value) when is_binary(value) do
      case Integer.parse(value) do
        {integer, ""} -> integer
        _other -> :invalid_timestamp
      end
    end

    def integer_timestamp(_value), do: :invalid_timestamp
  end

  defmodule LegacyLimits do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:allowed, :limit_reached, :primary, :secondary]

    @type t :: %__MODULE__{
            allowed: boolean() | nil,
            limit_reached: boolean() | nil,
            primary: LegacyWindow.t() | nil,
            secondary: LegacyWindow.t() | nil
          }
  end

  defmodule Legacy do
    @moduledoc false

    use JSONCodec, case: :camel, strict: true, fast_path: :json

    defstruct [
      :plan_type,
      :rate_limits,
      :rate_limit_reached_type,
      :spend_control_reached
    ]

    @type t :: %__MODULE__{
            plan_type: String.t() | nil,
            rate_limits: LegacyLimits.t(),
            rate_limit_reached_type: ReachedType.t() | nil,
            spend_control_reached: boolean() | nil
          }
  end

  @type t :: Current.t() | Legacy.t()

  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, shape} <- Shape.decode(json) do
      decode_shape(json, shape)
    end
  end

  defp decode_shape(json, %Shape{rate_limit: rate_limit, rate_limits: :missing})
       when rate_limit != :missing,
       do: Current.decode(json)

  defp decode_shape(json, %Shape{rate_limit: :missing, rate_limits: rate_limits})
       when rate_limits != :missing,
       do: Legacy.decode(json)

  defp decode_shape(_json, %Shape{rate_limit: :missing, rate_limits: :missing}),
    do: {:error, :unsupported_shape}

  defp decode_shape(_json, %Shape{}), do: {:error, :ambiguous_shape}
end
