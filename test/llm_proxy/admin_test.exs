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

    provider_token = Enum.find(contract.resources, &(&1.id == "provider_token"))

    assert Enum.map(provider_token.table.page_actions, & &1.id) == [
             "codex_oauth_start",
             "codex_oauth_complete"
           ]

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

  test "runs Codex OAuth start page action" do
    assert {:ok, %ActionResult.Job{id: "codex_oauth", meta: %{"oauth" => oauth}}} =
             LLMProxy.Admin.run_action("provider_token", "codex_oauth_start", %{}, %{})

    assert %{
             "authorization_url" => authorization_url,
             "state" => state,
             "verifier" => verifier
           } = oauth

    assert authorization_url =~ "https://auth.openai.com/oauth/authorize"
    assert authorization_url =~ URI.encode_query(%{state: state})
    assert is_binary(verifier)
  end

  test "stores Codex OAuth credentials from live admin process" do
    {:ok, credentials} =
      LLMProxy.Providers.OpenAICodex.OAuth.new(
        "access-token",
        "refresh-token",
        DateTime.utc_now() |> DateTime.add(3600, :second),
        "account-123"
      )

    assert {:ok, token} = LLMProxy.Admin.CodexOAuth.store_credentials(credentials)

    assert token.provider == "openai-codex"
    assert token.kind == "oauth"
    assert token.token == "access-token"
    assert token.refresh_token == "refresh-token"
    assert token.account_id == "account-123"
    assert token.label == "codex-login"
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
