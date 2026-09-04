defmodule LLMProxy.ProviderUsage.Adapters.CodexTest do
  use ExUnit.Case, async: true

  alias LLMProxy.ProviderUsage.Adapters.Codex

  test "parses primary and secondary Codex windows" do
    primary_reset = 1_800_000_000
    secondary_reset = 1_800_600_000

    body = %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{
        "available_count" => 2,
        "applicable_available_count" => 1
      },
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
    }

    assert {:ok, result} = body |> Jason.encode!() |> Codex.parse()
    assert result.plan == "pro"
    assert result.availability == :limited
    assert result.reset_credits_available == 2

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

  test "parses read-only Codex reset-credit visibility" do
    body = %{
      "available_count" => 2,
      "credits" => [
        %{
          "status" => "available",
          "granted_at" => "2026-08-21T23:59:26.045928Z",
          "expires_at" => "2026-09-20T23:59:26.045928Z"
        },
        %{
          "status" => "available",
          "granted_at" => "2026-08-22T23:59:26Z",
          "expires_at" => "2026-09-19T23:59:26Z"
        },
        %{
          "status" => "used",
          "granted_at" => "2026-08-01T00:00:00Z",
          "expires_at" => "not-used-for-visibility"
        }
      ]
    }

    assert {:ok, details} = body |> Jason.encode!() |> Codex.parse_reset_credit_details()
    assert details.available_count == 2
    assert details.expires_at == ~U[2026-09-19 23:59:26Z]

    assert {:error, {:invalid_response, _reason}} =
             %{"available_count" => -1, "credits" => []}
             |> Jason.encode!()
             |> Codex.parse_reset_credit_details()

    assert {:error, {:invalid_response, _reason}} =
             %{"credits" => []}
             |> Jason.encode!()
             |> Codex.parse_reset_credit_details()
  end

  test "parses the explicit legacy app-server shape" do
    body = %{
      "rateLimits" => %{
        "allowed" => false,
        "primary" => %{
          "usedPercent" => 20,
          "windowDurationMins" => 15,
          "resetsAt" => "1800000000"
        }
      }
    }

    assert {:ok, result} = body |> Jason.encode!() |> Codex.parse()
    assert result.availability == :unavailable
    assert [%{label: "15 minutes", used_percent: 20}] = result.windows
  end

  test "honors the exact current top-level provider limit state" do
    body = %{
      "rate_limit_reached_type" => %{"type" => "rate_limit_reached"},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 20,
          "limit_window_seconds" => 18_000
        }
      }
    }

    assert {:ok, result} = body |> Jason.encode!() |> Codex.parse()
    assert result.availability == :unavailable
  end

  test "rejects missing, malformed, ambiguous, and unknown usage data" do
    assert {:error, {:invalid_response, _reason}} =
             %{"plan_type" => "pro"} |> Jason.encode!() |> Codex.parse()

    assert {:error, :invalid_percent} =
             %{
               "rate_limit" => %{
                 "primary_window" => %{"used_percent" => 101}
               }
             }
             |> Jason.encode!()
             |> Codex.parse()

    assert {:error, :ambiguous_duration} =
             %{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 10,
                   "limit_window_seconds" => 18_000,
                   "window_minutes" => 300
                 }
               }
             }
             |> Jason.encode!()
             |> Codex.parse()

    assert {:error, :invalid_reached_type} =
             %{
               "rate_limit_reached_type" => %{"type" => "future_state"},
               "rate_limit" => %{
                 "primary_window" => %{"used_percent" => 10}
               }
             }
             |> Jason.encode!()
             |> Codex.parse()

    assert {:error, :invalid_plan} =
             %{
               "plan_type" => "private plan details",
               "rate_limit" => %{
                 "primary_window" => %{"used_percent" => 10}
               }
             }
             |> Jason.encode!()
             |> Codex.parse()

    for invalid_reset <- ["not-a-timestamp", 1.5] do
      assert {:error, {:invalid_response, _reason}} =
               %{
                 "rateLimits" => %{
                   "primary" => %{"usedPercent" => 10, "resetsAt" => invalid_reset}
                 }
               }
               |> Jason.encode!()
               |> Codex.parse()
    end

    assert {:error, {:invalid_response, :ambiguous_shape}} =
             %{"rate_limit" => %{}, "rateLimits" => %{}}
             |> Jason.encode!()
             |> Codex.parse()
  end

  test "rejects atom-keyed maps at the JSON boundary" do
    assert {:error, :invalid_response} = Codex.parse(%{rate_limit: %{}})
  end
end
