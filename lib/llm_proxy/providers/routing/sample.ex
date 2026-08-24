defmodule LLMProxy.Providers.Routing.Sample do
  @moduledoc """
  One deployment-attempt performance observation used by adaptive routing.
  """

  @enforce_keys [:operation, :stream, :outcome, :duration_ms, :observed_at]
  defstruct [
    :operation,
    :stream,
    :outcome,
    :duration_ms,
    :ttft_ms,
    :generation_ms,
    :output_tokens,
    :observed_at
  ]

  @type outcome :: :success | :error
  @type t :: %__MODULE__{
          operation: atom(),
          stream: boolean(),
          outcome: outcome(),
          duration_ms: non_neg_integer(),
          ttft_ms: non_neg_integer() | nil,
          generation_ms: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          observed_at: integer()
        }

  @spec tokens_per_second(t()) :: float() | nil
  def tokens_per_second(%__MODULE__{
        output_tokens: output_tokens,
        generation_ms: generation_ms
      })
      when is_integer(output_tokens) and output_tokens > 0 and is_integer(generation_ms) and
             generation_ms > 0 do
    output_tokens * 1_000 / generation_ms
  end

  def tokens_per_second(%__MODULE__{}), do: nil
end
