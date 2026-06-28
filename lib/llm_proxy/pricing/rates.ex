defmodule LLMProxy.Pricing.Rates do
  @moduledoc """
  Per-million-token pricing rates used by LLMProxy cost accounting.

  This is an internal contract. Callers pass atom-keyed, typed values only.
  """

  @enforce_keys []
  defstruct input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0

  @type t :: %__MODULE__{
          input: number(),
          output: number(),
          cache_read: number(),
          cache_write: number()
        }

  @spec zero() :: t()
  def zero, do: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(attrs \\ []) when is_list(attrs) do
    %__MODULE__{
      input: Keyword.get(attrs, :input, 0.0),
      output: Keyword.get(attrs, :output, 0.0),
      cache_read: Keyword.get(attrs, :cache_read, 0.0),
      cache_write: Keyword.get(attrs, :cache_write, 0.0)
    }
  end

  @spec put(t(), :input | :output | :cache_read | :cache_write, number()) :: t()
  def put(%__MODULE__{} = rates, key, value)
      when key in [:input, :output, :cache_read, :cache_write] and is_number(value) do
    Map.put(rates, key, value)
  end
end
