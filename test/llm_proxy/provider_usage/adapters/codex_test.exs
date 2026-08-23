defmodule LLMProxy.ProviderUsage.Adapters.CodexTest do
  use ExUnit.Case, async: true

  alias LLMProxy.ProviderUsage.Adapters.Codex

  test "parses primary and secondary Codex windows" do
    primary_reset = 1_800_000_000
    secondary_reset = 1_800_600_000

    assert {:ok, result} =
             Codex.parse(%{
               "plan_type" => "pro",
               "rate_limit" => %{
                 "allowed" => true,
                 "limit_reached" => false,
                 "primary_window" => %{
                   "used_percent" => 42,
                   "limit_window_seconds" => 18_000,
                   "reset_at" => primary_reset
                 },
                 "secondary_window" => %{
                   "used_percent" => 91.25,
                   "limit_window_seconds" => 604_800,
                   "reset_at" => secondary_reset
                 }
               }
             })

    assert result.plan == "pro"
    assert result.availability == :limited

    assert [primary, secondary] = result.windows
    assert primary.label == "5 hour"
    assert primary.used_percent == 42
    assert primary.remaining_percent == 58
    assert primary.resets_at == DateTime.from_unix!(primary_reset)

    assert secondary.label == "Weekly"
    assert secondary.used_percent == 91.3
    assert secondary.remaining_percent == 8.7
    assert secondary.resets_at == DateTime.from_unix!(secondary_reset)
  end

  test "honors provider availability and alternate app-server field names" do
    assert {:ok, result} =
             Codex.parse(%{
               "rate_limits" => %{
                 "allowed" => false,
                 "primary" => %{
                   "usedPercent" => 20,
                   "windowDurationMins" => 15,
                   "resetsAt" => "1800000000"
                 }
               }
             })

    assert result.availability == :unavailable
    assert [%{label: "15 minutes", used_percent: 20}] = result.windows
  end

  test "honors current top-level provider limit state" do
    assert {:ok, result} =
             Codex.parse(%{
               "rate_limit_reached_type" => %{"type" => "rate_limit_reached"},
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 20,
                   "limit_window_seconds" => 18_000
                 }
               }
             })

    assert result.availability == :unavailable
  end

  test "rejects missing and malformed usage data" do
    assert {:error, :unsupported} = Codex.parse(%{"plan_type" => "pro"})

    assert {:error, :invalid_response} =
             Codex.parse(%{
               "rate_limit" => %{
                 "primary_window" => %{"used_percent" => 101}
               }
             })
  end
end
