if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Dashboards.ProviderUsageTest do
    use ExUnit.Case, async: false

    @moduletag :incant

    alias LLMProxy.Admin.Dashboards.ProviderUsage

    test "returns the portable provider usage dashboard shape" do
      assert is_integer(ProviderUsage.accounts(%{}, %{}))
      assert is_integer(ProviderUsage.available(%{}, %{}))
      assert is_integer(ProviderUsage.exhausted(%{}, %{}))
      assert is_integer(ProviderUsage.attention(%{}, %{}))

      assert %{columns: columns, rows: rows} = ProviderUsage.usage_windows(%{}, %{})
      assert :provider in columns
      assert :account in columns
      assert :plan in columns
      assert :reset_credits_available in columns
      assert :reset_credit_expires_in in columns
      assert :reset_credit_expires_at in columns
      assert :used_ratio in columns
      assert :remaining_ratio in columns
      assert :resets_in in columns
      assert :resets_at in columns
      assert :last_refresh in columns
      assert :error in columns
      assert is_list(rows)
    end
  end
end
