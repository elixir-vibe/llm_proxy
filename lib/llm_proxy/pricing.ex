defmodule LLMProxy.Pricing do
  @moduledoc """
  Model pricing lookup and cost calculation.

  Pricing comes from the typed LLMDB runtime catalog.
  """

  alias LLMProxy.Usage

  def init, do: :ok

  def calculate_cost(model, %Usage{} = usage, provider \\ nil) do
    case get_pricing(model, provider) do
      nil ->
        0.0

      %LLMProxy.Pricing.Rates{} = rates ->
        (usage.input_tokens * rates.input +
           usage.output_tokens * rates.output +
           usage.cache_read_tokens * rates.cache_read +
           usage.cache_write_tokens * rates.cache_write) / 1_000_000
    end
  end

  def get_pricing(model, provider \\ nil) do
    LLMProxy.ModelDB.pricing(model, provider)
  end
end
