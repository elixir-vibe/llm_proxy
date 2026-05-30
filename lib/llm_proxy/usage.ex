defmodule LLMProxy.Usage do
  @moduledoc false

  defstruct input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer()
        }

  @spec zero() :: t()
  def zero, do: %__MODULE__{}

  @spec new(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def new(input_tokens, output_tokens, cache_read_tokens \\ 0, cache_write_tokens \\ 0) do
    %__MODULE__{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cache_read_tokens: cache_read_tokens,
      cache_write_tokens: cache_write_tokens
    }
  end

  @spec from_openai(map()) :: t()
  def from_openai(usage) do
    cache_read = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

    new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0, cache_read)
  end

  @spec from_responses(map()) :: t()
  def from_responses(usage) do
    cached = get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0
    input = (usage["input_tokens"] || 0) - cached

    new(input, usage["output_tokens"] || 0, cached)
  end

  @spec from_anthropic(map()) :: t()
  def from_anthropic(usage) do
    new(
      usage["input_tokens"] || 0,
      usage["output_tokens"] || 0,
      usage["cache_read_input_tokens"] || 0,
      usage["cache_creation_input_tokens"] || 0
    )
  end

  @spec merge_max(t(), t()) :: t()
  def merge_max(%__MODULE__{} = usage, %__MODULE__{} = event_usage) do
    %__MODULE__{
      input_tokens: max(usage.input_tokens, event_usage.input_tokens),
      output_tokens: max(usage.output_tokens, event_usage.output_tokens),
      cache_read_tokens: max(usage.cache_read_tokens, event_usage.cache_read_tokens),
      cache_write_tokens: max(usage.cache_write_tokens, event_usage.cache_write_tokens)
    }
  end

  @spec put_output_tokens(t(), non_neg_integer()) :: t()
  def put_output_tokens(%__MODULE__{} = usage, output_tokens) do
    %{usage | output_tokens: output_tokens}
  end
end
