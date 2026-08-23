defmodule LLMProxy.ProviderUsage.Adapters.GLMTest do
  use ExUnit.Case, async: true

  alias LLMProxy.ProviderUsage.Adapters.GLM

  test "parses current GLM credit windows and reset times" do
    five_hour_reset = 1_787_176_502_893
    weekly_reset = 1_787_607_163_997

    assert {:ok, result} =
             GLM.parse(%{
               "code" => 200,
               "success" => true,
               "data" => %{
                 "level" => "lite",
                 "limits" => [
                   %{
                     "type" => "CREDIT_LIMIT",
                     "unit" => 3,
                     "number" => 5,
                     "usage" => 2_000,
                     "currentValue" => 1_653,
                     "remaining" => 346,
                     "percentage" => 82,
                     "nextResetTime" => five_hour_reset
                   },
                   %{
                     "type" => "CREDIT_LIMIT",
                     "unit" => 6,
                     "number" => 1,
                     "percentage" => 45,
                     "nextResetTime" => weekly_reset
                   }
                 ]
               }
             })

    assert result.plan == "lite"
    assert result.availability == :available
    assert [five_hour, weekly] = result.windows

    assert {five_hour.label, five_hour.used_percent, five_hour.remaining_percent} ==
             {"5 hour", 82, 18}

    assert five_hour.resets_at ==
             five_hour_reset
             |> DateTime.from_unix!(:millisecond)
             |> DateTime.truncate(:second)

    assert {weekly.label, weekly.used_percent, weekly.remaining_percent} == {"Weekly", 45, 55}

    assert weekly.resets_at ==
             weekly_reset
             |> DateTime.from_unix!(:millisecond)
             |> DateTime.truncate(:second)
  end

  test "keeps an explicitly absent reset and supports legacy token and tool limits" do
    assert {:ok, result} =
             GLM.parse(%{
               "data" => %{
                 "limits" => [
                   %{
                     "type" => "TOKENS_LIMIT",
                     "unit" => 3,
                     "number" => 5,
                     "percentage" => 100
                   },
                   %{
                     "type" => "TIME_LIMIT",
                     "percentage" => 12,
                     "nextResetTime" => 1_800_000_000
                   }
                 ]
               }
             })

    assert result.availability == :unavailable
    assert [%{label: "5 hour", resets_at: nil}, %{label: "Monthly tools"}] = result.windows
  end

  test "reports authentication, unsupported, and invalid shapes" do
    assert {:error, :authentication_failed} = GLM.parse(%{"code" => 401})
    assert {:error, :unsupported} = GLM.parse(%{"success" => false})
    assert {:error, :unsupported} = GLM.parse(%{"data" => %{"limits" => []}})

    assert {:error, :invalid_response} =
             GLM.parse(%{
               "data" => %{
                 "limits" => [%{"type" => "TOKENS_LIMIT", "percentage" => -1}]
               }
             })
  end
end
