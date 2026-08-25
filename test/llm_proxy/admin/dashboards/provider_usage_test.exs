if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Dashboards.ProviderUsageTest do
    use ExUnit.Case, async: false

    @moduletag :incant

    alias LLMProxy.Admin.Dashboards.ProviderUsage

    test "returns the portable provider usage dashboard shape" do
      assert is_integer(ProviderUsage.accounts(%{}, %{}))
      assert is_integer(ProviderUsage.available(%{}, %{}))
      assert is_integer(ProviderUsage.attention(%{}, %{}))

      assert %{columns: columns, rows: rows} = ProviderUsage.usage_windows(%{}, %{})
      assert :provider in columns
      assert :account in columns
      assert :used_percent in columns
      assert :remaining_percent in columns
      assert :resets_at in columns
      assert :last_refresh in columns
      assert :error in columns
      assert is_list(rows)
    end
  end
end
