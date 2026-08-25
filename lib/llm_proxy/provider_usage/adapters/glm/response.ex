defmodule LLMProxy.ProviderUsage.Adapters.GLM.Response do
  @moduledoc false

  defmodule Shape do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct data: :missing, limits: :missing, code: :missing, success: :missing

    @type t :: %__MODULE__{
            data: term(),
            limits: term(),
            code: term(),
            success: term()
          }
  end

  defmodule Limit do
    @moduledoc false

    use JSONCodec, case: :camel, strict: true, fast_path: :json

    defstruct [:type, :unit, :number, :percentage, :next_reset_time]

    @type t :: %__MODULE__{
            type: String.t(),
            unit: integer() | nil,
            number: number() | nil,
            percentage: number(),
            next_reset_time: integer() | nil
          }
  end

  defmodule Data do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:level, :limits]

    @type t :: %__MODULE__{level: String.t() | nil, limits: [Limit.t()]}
  end

  defmodule Envelope do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:code, :success, :data]

    @type t :: %__MODULE__{
            code: integer() | nil,
            success: boolean() | nil,
            data: Data.t()
          }
  end

  defmodule Authentication do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:code]

    @type t :: %__MODULE__{code: integer()}
  end

  defmodule Failure do
    @moduledoc false

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:code, :success]

    @type t :: %__MODULE__{code: integer() | nil, success: boolean()}
  end

  @type t :: Envelope.t() | Data.t() | Authentication.t() | Failure.t()

  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, shape} <- Shape.decode(json) do
      decode_shape(json, shape)
    end
  end

  defp decode_shape(json, %Shape{data: data, limits: :missing}) when data != :missing,
    do: Envelope.decode(json)

  defp decode_shape(json, %Shape{
         data: :missing,
         limits: limits,
         code: :missing,
         success: :missing
       })
       when limits != :missing,
       do: Data.decode(json)

  defp decode_shape(json, %Shape{
         data: :missing,
         limits: :missing,
         code: code,
         success: :missing
       })
       when code != :missing,
       do: Authentication.decode(json)

  defp decode_shape(json, %Shape{
         data: :missing,
         limits: :missing,
         success: success
       })
       when success != :missing,
       do: Failure.decode(json)

  defp decode_shape(_json, %Shape{}), do: {:error, :unsupported_or_ambiguous_shape}
end
