defmodule LLMProxy.PricingTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Pricing

  describe "calculate_cost/2" do
    test "calculates cost for a known model" do
      pricing = Pricing.get_pricing("gpt-4o")
      assert pricing != nil

      usage = %{input_tokens: 1000, output_tokens: 500, cache_read_tokens: 0, cache_write_tokens: 0}
      cost = Pricing.calculate_cost("gpt-4o", usage)

      expected = (1000 * pricing["input"] + 500 * pricing["output"]) / 1_000_000
      assert_in_delta cost, expected, 0.0000001
    end

    test "returns 0 for unknown model" do
      usage = %{input_tokens: 1000, output_tokens: 500}
      assert Pricing.calculate_cost("unknown-model-xyz", usage) == 0.0
    end

    test "includes cache costs" do
      pricing = Pricing.get_pricing("claude-sonnet-4-20250514")

      if pricing do
        usage = %{
          input_tokens: 1000,
          output_tokens: 500,
          cache_read_tokens: 2000,
          cache_write_tokens: 300
        }

        cost = Pricing.calculate_cost("claude-sonnet-4-20250514", usage)

        expected =
          (1000 * pricing["input"] + 500 * pricing["output"] +
             2000 * pricing["cache_read"] + 300 * pricing["cache_write"]) / 1_000_000

        assert_in_delta cost, expected, 0.0000001
      end
    end

    test "handles missing cache token fields in usage" do
      usage = %{input_tokens: 100, output_tokens: 50}
      cost = Pricing.calculate_cost("gpt-4o", usage)
      assert cost > 0.0
    end
  end

  describe "get_pricing/1" do
    test "returns pricing for known models" do
      pricing = Pricing.get_pricing("gpt-4o")
      assert is_map(pricing)
      assert is_number(pricing["input"])
      assert is_number(pricing["output"])
    end

    test "returns nil for unknown model" do
      assert Pricing.get_pricing("nonexistent-model") == nil
    end
  end
end
