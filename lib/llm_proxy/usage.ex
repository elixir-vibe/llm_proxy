defmodule LLMProxy.Usage do
  @moduledoc """
  Token usage accounting and protocol usage-map rendering.
  """

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

  @spec to_openai(map() | t() | nil) :: map()
  def to_openai(nil), do: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}

  def to_openai(usage) when is_map(usage) do
    input = token_count(usage, :input_tokens)
    output = token_count(usage, :output_tokens)
    cached = token_count(usage, :cache_read_tokens, :cached_tokens)

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => Map.get(usage, :total_tokens) || input + output,
      "prompt_tokens_details" => %{"cached_tokens" => cached}
    }
  end

  @spec to_responses(map() | t() | nil) :: map()
  def to_responses(nil), do: %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}

  def to_responses(usage) when is_map(usage) do
    input = token_count(usage, :input_tokens)
    output = token_count(usage, :output_tokens)
    cached = token_count(usage, :cache_read_tokens, :cached_tokens)

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => Map.get(usage, :total_tokens) || input + output,
      "input_tokens_details" => %{"cached_tokens" => cached}
    }
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

  defp token_count(usage, key, fallback_key \\ nil) do
    Map.get(usage, key) || fallback_count(usage, fallback_key) || 0
  end

  defp fallback_count(_usage, nil), do: nil
  defp fallback_count(usage, key), do: Map.get(usage, key)
end
