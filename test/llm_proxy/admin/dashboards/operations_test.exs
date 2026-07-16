defmodule LLMProxy.Admin.Dashboards.OperationsTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Admin.Dashboards.Operations
  alias LLMProxy.Storage

  setup do
    LLMProxy.TestSupport.checkout_repo()
  end

  test "reports LLMProxy storage statistics" do
    {:ok, key, _raw_key} = Storage.create_key("dashboard-widget-user")
    Storage.update_key_usage(key, %{input: 123, output: 45, cost_usd: 0.67})

    assert {:ok, _usage} =
             Storage.record_usage(%{
               key_id: key.id,
               model: "dashboard-model",
               input_tokens: 123,
               output_tokens: 45,
               cost_usd: 0.67,
               provider: "openai",
               timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    assert Operations.total_keys(%{}, %{}) == 1
    assert Operations.total_requests(%{}, %{}) == 1
    assert Operations.total_spend(%{}, %{}) == 0.67
    assert Operations.input_tokens(%{}, %{}) == 123
    assert Operations.output_tokens(%{}, %{}) == 45

    assert %{
             columns: [
               :timestamp,
               :provider,
               :model,
               :input_tokens,
               :output_tokens,
               :cost_usd,
               :duration_ms,
               :ttft_ms,
               :key_id
             ],
             rows: [%{model: "dashboard-model"}]
           } = Operations.recent_usage(%{}, %{})

    assert %{columns: [:service, :count], rows: []} = Operations.service_usage(%{}, %{})
  end
end
