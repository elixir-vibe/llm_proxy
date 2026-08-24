if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.AdminTest do
    use ExUnit.Case, async: true

    @moduletag :incant

    test "declares the LLMProxy Incant contract" do
      assert %Incant.Admin.Contract{} = contract = Incant.Admin.describe(LLMProxy.Admin)

      assert contract.id == "llm_proxy"
      assert contract.service == :llm_proxy
      assert contract.version == "1"
      assert contract.opts.title == "LLM Proxy"

      assert Enum.map(contract.resources, & &1.id) == [
               "api_key",
               "provider_token",
               "trace",
               "message"
             ]

      assert [%{id: "api_key", title: "API Keys"} = api_key | _] = contract.resources

      assert Enum.map(api_key.table.columns, & &1.id) == [
               "name",
               "enabled",
               "total_spend_usd",
               "input_tokens",
               "output_tokens",
               "cache_read_tokens",
               "trace_requests",
               "capture_content"
             ]

      assert Enum.map(api_key.table.columns, & &1.opts[:priority]) == [
               :primary,
               :primary,
               :primary,
               :secondary,
               :secondary,
               :tertiary,
               :secondary,
               :secondary
             ]

      assert Enum.map(api_key.table.actions, & &1.id) == ["delete", "disable", "enable"]
      assert Enum.map(api_key.table.page_actions, & &1.id) == ["create"]
      refute Map.has_key?(api_key.opts, :schema)

      provider_token = Enum.find(contract.resources, &(&1.id == "provider_token"))
      trace = Enum.find(contract.resources, &(&1.id == "trace"))
      message = Enum.find(contract.resources, &(&1.id == "message"))

      assert Enum.find(trace.table.columns, &(&1.id == "key_id")).opts[:format] == :id
      assert Enum.find(message.table.columns, &(&1.id == "key_id")).opts[:format] == :id

      assert Enum.map(message.table.columns, & &1.id) == [
               "timestamp",
               "key_id",
               "model",
               "route",
               "input_tokens",
               "output_tokens",
               "user_message"
             ]

      assert Enum.find(message.table.columns, &(&1.id == "user_message")).opts[:sensitive]

      secret = "seeded-admin-message-2d4a"
      message_resource = Incant.metadata(LLMProxy.Admin.Resources.Message)

      redacted =
        Incant.Sensitive.redact_row(
          %{id: 1, model: "test", user_message: secret},
          message_resource
        )

      assert redacted.user_message == "[redacted]"
      refute inspect(redacted) =~ secret

      assert Enum.map(provider_token.table.page_actions, & &1.id) == [
               "codex_oauth_start",
               "codex_oauth_complete",
               "refresh_all_usage"
             ]

      provider_filter = Enum.find(provider_token.table.filters, &(&1.id == "provider"))
      assert provider_filter.type == :text

      model_filter = Enum.find(message.table.filters, &(&1.id == "model"))
      assert model_filter.type == :combobox
      assert model_filter.opts.options_from == :model

      enabled_column = Enum.find(provider_token.table.columns, &(&1.id == "enabled"))
      assert enabled_column.opts.true_label == "Enabled"
      assert enabled_column.opts.false_label == "Disabled"

      provider_metadata = Incant.metadata(LLMProxy.Admin.Resources.ProviderToken)
      enable = Enum.find(provider_metadata.table.actions, &(&1.name == :enable))
      disable = Enum.find(provider_metadata.table.actions, &(&1.name == :disable))
      refresh_usage = Enum.find(provider_metadata.table.actions, &(&1.name == :refresh_usage))

      assert enable.opts[:callback] == {LLMProxy.Admin.Resources.ProviderToken, :enable}
      assert enable.opts[:available_if] == [enabled: false]
      assert disable.opts[:callback] == {LLMProxy.Admin.Resources.ProviderToken, :disable}
      assert disable.opts[:available_if] == [enabled: true]
      assert disable.opts[:confirm] == "Disable this provider token?"
      assert Enum.find(provider_metadata.table.columns, &(&1.name == :proxy)).opts[:sensitive]
      assert refresh_usage.opts[:available_if] == [enabled: true]

      assert [
               %{id: "operations", title: "Operations"} = dashboard,
               %{id: "provider_usage", title: "Provider Usage"} = provider_usage
             ] = contract.dashboards

      assert Enum.map(dashboard.widgets, & &1.id) == [
               "api_keys",
               "requests",
               "spend",
               "input_tokens",
               "output_tokens",
               "recent_usage",
               "service_usage"
             ]

      assert dashboard.grid == %{columns: 10}
      assert Enum.map(dashboard.widgets, & &1.opts[:span]) == [2, 2, 2, 2, 2, 7, 3]

      recent_usage = Enum.find(dashboard.widgets, &(&1.id == "recent_usage"))

      assert Enum.map(recent_usage.opts.columns, & &1.name) == [
               :timestamp,
               :provider,
               :model,
               :input_tokens,
               :output_tokens,
               :cost_usd,
               :duration_ms,
               :ttft_ms,
               :key_id
             ]

      assert Enum.map(recent_usage.opts.columns, & &1.opts[:label]) == [
               "Timestamp",
               "Provider",
               "Model",
               "Input tokens",
               "Output tokens",
               "Cost",
               "Duration",
               "TTFT",
               "Key"
             ]

      assert recent_usage.opts.preview_rows == 10

      assert Enum.map(recent_usage.opts.columns, & &1.opts[:priority]) == [
               :primary,
               :secondary,
               :primary,
               :secondary,
               :tertiary,
               :secondary,
               :tertiary,
               :tertiary,
               :tertiary
             ]

      assert Enum.all?(dashboard.widgets, fn widget -> not Map.has_key?(widget.opts, :query) end)

      assert Enum.map(provider_usage.widgets, & &1.id) == [
               "accounts",
               "available",
               "exhausted",
               "attention",
               "usage_windows"
             ]

      usage_windows = Enum.find(provider_usage.widgets, &(&1.id == "usage_windows"))

      assert Enum.map(usage_windows.opts.columns, & &1.name) == [
               :account,
               :provider,
               :window,
               :remaining_ratio,
               :resets_in,
               :availability,
               :reset_credits_available,
               :reset_credit_expires_in
             ]

      assert usage_windows.opts.preview_rows == 50
      assert Enum.all?(provider_usage.widgets, &(!Map.has_key?(&1.opts, :query)))
    end
  end
end
