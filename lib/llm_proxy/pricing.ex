defmodule LLMProxy.Pricing do
  @moduledoc """
  Model pricing lookup and cost calculation.

  Pricing comes from LLMDB first, with priv/models/pricing.json as a local fallback.
  """

  alias LLMProxy.Usage

  @pricing_key :llm_proxy_pricing

  @pricing_path Path.join(:code.priv_dir(:llm_proxy), "models/pricing.json")
  @external_resource @pricing_path

  def init do
    pricing =
      case File.read(@pricing_path) do
        {:ok, data} -> Jason.decode!(data)
        {:error, _} -> %{}
      end

    :persistent_term.put(@pricing_key, pricing)
  end

  def calculate_cost(model, %Usage{} = usage, provider \\ nil) do
    case get_pricing(model, provider) do
      nil ->
        0.0

      pricing ->
        (usage.input_tokens * (pricing["input"] || 0) +
           usage.output_tokens * (pricing["output"] || 0) +
           usage.cache_read_tokens * (pricing["cache_read"] || 0) +
           usage.cache_write_tokens * (pricing["cache_write"] || 0)) / 1_000_000
    end
  end

  def get_pricing(model, provider \\ nil) do
    LLMProxy.ModelDB.pricing(model, provider) || local_pricing(model)
  end

  defp local_pricing(model) do
    pricing = :persistent_term.get(@pricing_key, %{})
    Map.get(pricing, model)
  end
end
