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

    variables = %{"range" => "24h"}

    assert Operations.total_keys(variables, %{}) == 1
    assert Operations.total_requests(variables, %{}) == 1
    assert Operations.total_spend(variables, %{}) == 0.67
    assert Operations.input_tokens(variables, %{}) == 123
    assert Operations.output_tokens(variables, %{}) == 45

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
           } = Operations.recent_usage(variables, %{})

    assert %{columns: [:service, :count], rows: []} = Operations.service_usage(variables, %{})
  end

  test "applies preset and custom dashboard ranges" do
    {:ok, key, _raw_key} = Storage.create_key("range-user")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for timestamp <- [DateTime.add(now, -2, :hour), DateTime.add(now, -20, :minute)] do
      assert {:ok, _usage} =
               Storage.record_usage(%{
                 key_id: key.id,
                 model: "range-model",
                 input_tokens: 10,
                 output_tokens: 5,
                 cost_usd: 0.1,
                 provider: "openai",
                 timestamp: timestamp
               })
    end

    assert Operations.total_requests(%{"range" => "1h"}, %{}) == 1
    assert Operations.total_requests(%{"range" => "24h"}, %{}) == 2

    today = Date.to_iso8601(Date.utc_today())

    assert Operations.total_requests(
             %{"range" => %{"from" => today, "to" => today}},
             %{}
           ) == 2
  end
end
