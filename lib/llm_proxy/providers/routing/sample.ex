defmodule LLMProxy.Providers.Routing.Sample do
  @moduledoc """
  One deployment-attempt performance observation used by adaptive routing.
  """

  @operations [:openai_chat, :openai_responses, :anthropic_messages]
  @outcomes [:success, :error]

  @enforce_keys [:operation, :stream, :outcome, :duration_ms, :observed_at]
  defstruct [:operation, :stream, :outcome, :duration_ms, :ttft_ms, :output_tokens, :observed_at]

  @type outcome :: :success | :error
  @type t :: %__MODULE__{
          operation: :openai_chat | :openai_responses | :anthropic_messages,
          stream: boolean(),
          outcome: outcome(),
          duration_ms: non_neg_integer(),
          ttft_ms: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          observed_at: integer()
        }

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = sample) do
    if valid_identity?(sample) and valid_measurements?(sample) and valid_timestamp?(sample) do
      sample
    else
      raise ArgumentError, "invalid routing performance sample"
    end
  end

  defp valid_identity?(sample) do
    sample.operation in @operations and sample.outcome in @outcomes and is_boolean(sample.stream)
  end

  defp valid_measurements?(sample) do
    non_negative_integer?(sample.duration_ms) and valid_ttft?(sample) and
      optional_non_negative_integer?(sample.output_tokens)
  end

  defp valid_ttft?(%{ttft_ms: nil}), do: true

  defp valid_ttft?(sample) do
    non_negative_integer?(sample.ttft_ms) and sample.ttft_ms <= sample.duration_ms
  end

  defp valid_timestamp?(sample), do: is_integer(sample.observed_at)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: non_negative_integer?(value)
end
