defmodule LLMProxy.AdminTest do
  use ExUnit.Case, async: true

  test "describes LLMProxy admin as a portable Incant contract" do
    assert %Incant.Admin.Contract{} = contract = Incant.Admin.describe(LLMProxy.Admin)

    assert contract.id == "llm_proxy"
    assert contract.service == :llm_proxy
    assert contract.version == "1"

    resource_ids = Enum.map(contract.resources, & &1.id)
    assert resource_ids == ["api_key", "provider_token", "trace", "message"]

    assert [%{id: "api_key", title: "API Keys"} = api_key | _] = contract.resources

    assert Enum.map(api_key.table.columns, & &1.id) == [
             "name",
             "total_spend_usd",
             "input_tokens",
             "output_tokens",
             "cache_read_tokens",
             "trace_requests"
           ]

    assert Enum.map(api_key.table.actions, & &1.id) == ["show_usage", "rotate", "delete"]
    refute Map.has_key?(api_key.opts, :schema)

    assert [%{id: "operations", title: "Operations"} = dashboard] = contract.dashboards

    assert Enum.map(dashboard.widgets, & &1.id) == [
             "api_keys",
             "requests",
             "spend",
             "input_tokens",
             "output_tokens",
             "recent_usage",
             "service_usage"
           ]

    assert Enum.all?(dashboard.widgets, fn widget -> not Map.has_key?(widget.opts, :query) end)
  end
end
