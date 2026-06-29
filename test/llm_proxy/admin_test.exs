defmodule LLMProxy.AdminTest do
  use ExUnit.Case, async: false

  alias Incant.ActionResult
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
  end

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

    assert Enum.map(api_key.table.actions, & &1.id) == ["delete"]
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

  test "runs implemented API key and token row actions" do
    {:ok, key, _raw_key} = Storage.create_key("admin-delete")
    {:ok, token} = Storage.add_token("openai", "api-key", "admin-token")

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "disable",
               %{id: to_string(token.id)},
               %{}
             )

    [disabled] = Storage.list_tokens(%{provider: "openai"})
    assert disabled.enabled == false

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "enable",
               %{id: to_string(token.id)},
               %{}
             )

    [enabled] = Storage.list_tokens(%{provider: "openai"})
    assert enabled.enabled == true

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "remove",
               %{id: to_string(token.id)},
               %{}
             )

    assert Storage.list_tokens(%{provider: "openai"}) == []

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action("api_key", "delete", %{id: key.id}, %{})

    assert Storage.list_keys() == []
  end
end
