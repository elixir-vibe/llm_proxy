defmodule LLMProxy.ProviderUsage.Adapters.GLMTest do
  use ExUnit.Case, async: true

  alias LLMProxy.ProviderUsage.Adapters.GLM

  test "parses current GLM credit windows and reset times" do
    five_hour_reset = 1_787_176_502_893
    weekly_reset = 1_787_607_163_997

    body = %{
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
    }

    assert {:ok, result} = body |> Jason.encode!() |> GLM.parse()
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

  test "keeps an explicitly absent reset and supports exact token and tool limits" do
    body = %{
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

    assert {:ok, result} = body |> Jason.encode!() |> GLM.parse()
    assert result.availability == :unavailable
    assert [%{label: "5 hour", resets_at: nil}, %{label: "Monthly tools"}] = result.windows
  end

  test "reports authentication, unsupported, and invalid shapes" do
    assert {:error, :authentication_failed} =
             %{"code" => 401} |> Jason.encode!() |> GLM.parse()

    assert {:error, :unsupported} =
             %{"success" => false} |> Jason.encode!() |> GLM.parse()

    assert {:error, :unsupported} =
             %{"data" => %{"limits" => []}} |> Jason.encode!() |> GLM.parse()

    assert {:error, :invalid_response} =
             %{
               "data" => %{
                 "limits" => [%{"type" => "TOKENS_LIMIT", "percentage" => -1}]
               }
             }
             |> Jason.encode!()
             |> GLM.parse()
  end

  test "rejects malformed entries and unknown limit types instead of dropping them" do
    assert {:error, {:invalid_response, _reason}} =
             %{
               "data" => %{
                 "limits" => [
                   %{"type" => "CREDIT_LIMIT", "percentage" => 20},
                   "malformed"
                 ]
               }
             }
             |> Jason.encode!()
             |> GLM.parse()

    assert {:error, :unknown_limit_type} =
             %{
               "data" => %{
                 "limits" => [%{"type" => "FUTURE_LIMIT", "percentage" => 20}]
               }
             }
             |> Jason.encode!()
             |> GLM.parse()

    assert {:error, {:invalid_response, :unsupported_or_ambiguous_shape}} =
             %{"data" => %{"limits" => []}, "limits" => []}
             |> Jason.encode!()
             |> GLM.parse()
  end

  test "rejects atom-keyed maps at the JSON boundary" do
    assert {:error, :invalid_response} = GLM.parse(%{data: %{limits: []}})
  end
end
