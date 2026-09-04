defmodule LLMProxy.ProviderUsageTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias LLMProxy.Provider.TokenCodec.AESGCM
  alias LLMProxy.ProviderUsage.Adapters.Codex
  alias LLMProxy.ProviderUsage.{HTTP, Loader, Snapshot, Source, Window}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias Req.Test, as: ReqTest

  @codec_key Base.encode64(:binary.copy(<<7>>, 32))

  defmodule UsageStub do
  end

  setup do
    TestSupport.checkout_repo()
    TestSupport.clear_provider_tokens()

    saved =
      Map.new([:providers, :provider_token_codec, :req_plug], fn key ->
        {key, Application.fetch_env(:llm_proxy, key)}
      end)

    Application.put_env(
      :llm_proxy,
      :provider_token_codec,
      {AESGCM, active_key_id: "usage", keys: %{"usage" => @codec_key}}
    )

    Application.put_env(:llm_proxy, :req_plug, {ReqTest, UsageStub})

    Application.put_env(:llm_proxy, :providers, %{
      "glm-main" => %{
        adapter: "zai_coding_plan",
        base_url: "https://api.z.ai/api/coding/paas/v4",
        token_pool: "glm-pool"
      }
    })

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:llm_proxy, key, value)
        {key, :error} -> Application.delete_env(:llm_proxy, key)
      end)
    end)

    :ok
  end

  test "loads encrypted Codex and GLM credentials but returns only redacted state" do
    ReqTest.stub(UsageStub, fn conn ->
      case conn.request_path do
        "/backend-api/wham/usage" ->
          assert get_req_header(conn, "authorization") == ["Bearer codex-access-secret"]
          assert get_req_header(conn, "chatgpt-account-id") == ["account-private-id"]

          ReqTest.json(conn, %{
            "rate_limit_reset_credits" => %{"available_count" => 1},
            "rate_limit" => %{
              "allowed" => true,
              "primary_window" => %{
                "used_percent" => 25,
                "limit_window_seconds" => 18_000,
                "reset_at" => 1_800_000_000
              }
            }
          })

        "/backend-api/wham/rate-limit-reset-credits" ->
          assert get_req_header(conn, "authorization") == ["Bearer codex-access-secret"]
          assert get_req_header(conn, "chatgpt-account-id") == ["account-private-id"]
          assert get_req_header(conn, "openai-beta") == ["codex-1"]
          assert get_req_header(conn, "originator") == ["codex_cli_rs"]

          ReqTest.json(conn, %{
            "available_count" => 1,
            "credits" => [
              %{
                "status" => "available",
                "granted_at" => "2026-08-21T23:59:26.045928Z",
                "expires_at" => "2026-09-20T23:59:26.045928Z"
              }
            ]
          })

        "/api/monitor/usage/quota/limit" ->
          assert get_req_header(conn, "authorization") == ["glm-api-secret"]
          send_resp(conn, 401, ~s({"code":401}))

        "/api/monitor/usage" ->
          assert get_req_header(conn, "authorization") == ["glm-api-secret"]

          ReqTest.json(conn, %{
            "code" => 200,
            "success" => true,
            "data" => %{
              "limits" => [
                %{
                  "type" => "CREDIT_LIMIT",
                  "unit" => 3,
                  "number" => 5,
                  "percentage" => 40,
                  "nextResetTime" => 1_800_000_000_000
                }
              ]
            }
          })
      end
    end)

    assert {:ok, codex} =
             Storage.add_token("openai-codex", "oauth", "codex-access-secret", %{
               account_id: "account-private-id",
               label: "owner@example.com"
             })

    assert {:ok, glm} =
             Storage.add_token("glm-pool", "api-key", "glm-api-secret", %{label: "prod-east"})

    refute codex.token == "codex-access-secret"
    refute glm.token == "glm-api-secret"

    sources = Source.accounts()
    assert Enum.map(sources, & &1.token_id) == [codex.id, glm.id]
    assert Source.supported_account?(codex.id)
    assert hd(sources).usage_paths == ["/backend-api/wham/usage"]

    source_text = inspect(sources)
    refute source_text =~ "codex-access-secret"
    refute source_text =~ "glm-api-secret"
    refute source_text =~ "account-private-id"
    refute source_text =~ "owner@example.com"

    assert [codex_snapshot, glm_snapshot] = Loader.refresh(:all)
    assert codex_snapshot.account_label == "Account ##{codex.id}"
    assert codex_snapshot.state == :fresh
    assert codex_snapshot.availability == :available
    assert codex_snapshot.reset_credits_available == 1
    assert codex_snapshot.reset_credit_expires_at == ~U[2026-09-20 23:59:26Z]
    assert [%{used_percent: 25, remaining_percent: 75}] = codex_snapshot.windows

    assert glm_snapshot.account_label == "p***t · ##{glm.id}"
    assert glm_snapshot.state == :fresh
    assert [%{used_percent: 40, remaining_percent: 60}] = glm_snapshot.windows

    snapshot_text = inspect([codex_snapshot, glm_snapshot])
    refute snapshot_text =~ "codex-access-secret"
    refute snapshot_text =~ "glm-api-secret"
    refute snapshot_text =~ "account-private-id"
  end

  test "keeps provider response details out of error state" do
    ReqTest.stub(UsageStub, fn conn ->
      send_resp(conn, 500, "glm-api-secret account-private-id")
    end)

    assert {:ok, token} =
             Storage.add_token("glm-pool", "api-key", "glm-api-secret", %{
               label: "unsafe@example.com"
             })

    assert [snapshot] = Loader.refresh({:account, token.id})
    assert snapshot.account_label == "Account ##{token.id}"
    assert snapshot.state == :error
    assert snapshot.error == "Provider usage API is unavailable"
    refute inspect(snapshot) =~ "glm-api-secret"
    refute inspect(snapshot) =~ "account-private-id"
  end

  test "keeps Codex quota visible when reset-credit details are unavailable" do
    ReqTest.stub(UsageStub, fn conn ->
      case conn.request_path do
        "/backend-api/wham/usage" ->
          ReqTest.json(conn, %{
            "rate_limit_reset_credits" => %{"available_count" => 1},
            "rate_limit" => %{
              "primary_window" => %{
                "used_percent" => 25,
                "limit_window_seconds" => 18_000
              }
            }
          })

        "/backend-api/wham/rate-limit-reset-credits" ->
          send_resp(conn, 503, ~s({"error":"temporary"}))
      end
    end)

    assert {:ok, token} =
             Storage.add_token("openai-codex", "oauth", "codex-access-secret", %{
               account_id: "account-private-id"
             })

    assert [snapshot] = Loader.refresh({:account, token.id})
    assert snapshot.state == :fresh
    assert snapshot.reset_credits_available == 1
    assert snapshot.reset_credit_expires_at == nil
    assert [%{used_percent: 25}] = snapshot.windows
  end

  test "uses the first-party Codex path style for default and custom bases" do
    assert {:ok, _token} = Storage.add_token("openai-codex", "oauth", "access")

    Application.put_env(:llm_proxy, :providers, %{
      "openai-codex" => %{base_url: "https://chatgpt.com"}
    })

    assert [%{base_url: "https://chatgpt.com/backend-api"} = source] = Source.accounts()
    assert source.usage_paths == ["/backend-api/wham/usage"]
    assert source.config_error == nil

    Application.put_env(:llm_proxy, :providers, %{
      "openai-codex" => %{base_url: "https://codex.example/v2"}
    })

    assert [source] = Source.accounts()
    assert source.usage_paths == ["/v2/api/codex/usage"]

    Application.put_env(:llm_proxy, :providers, %{
      "openai-codex" => %{base_url: "http://codex.example"}
    })

    assert [%{config_error: "Codex usage base URL is not a valid HTTPS URL"}] =
             Source.accounts()
  end

  test "does not send credentials for per-token endpoint overrides" do
    ReqTest.stub(UsageStub, fn _conn ->
      flunk("usage request must not be sent")
    end)

    assert {:ok, token} =
             Storage.add_token("glm-pool", "api-key", "glm-api-secret", %{
               proxy: "https://gateway.example/v1"
             })

    assert {:error, :unsupported} =
             LLMProxy.ProviderUsage.refresh_account(Integer.to_string(token.id))

    assert [snapshot] = Loader.refresh({:account, token.id})
    assert snapshot.state == :error

    assert snapshot.error ==
             "Provider usage is unavailable for tokens with endpoint overrides"
  end

  test "rejects oversized provider responses before JSON decoding" do
    ReqTest.stub(UsageStub, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"padding":"#{String.duplicate("x", 256_001)}"}))
    end)

    assert {:ok, token} = Storage.add_token("glm-pool", "api-key", "glm-api-secret")
    assert [snapshot] = Loader.refresh({:account, token.id})
    assert snapshot.state == :error
    assert snapshot.error == "Provider returned invalid usage data"
  end

  test "builds the real Finch request with compatible timeout options" do
    Application.delete_env(:llm_proxy, :req_plug)

    source = %Source{
      token_id: 1,
      stored_token: nil,
      adapter: Codex,
      provider_label: "Provider",
      account_label: "Account #1",
      base_url: "https://127.0.0.1:1",
      usage_paths: ["/usage"]
    }

    assert {:error, :unavailable} = HTTP.get(source, "/usage", [{"accept", "application/json"}])
  end

  test "uses fresh upstream availability and recovers at the reported reset" do
    now = DateTime.utc_now()
    reset = DateTime.add(now, 60, :second)

    assert LLMProxy.ProviderUsage.available_snapshot?(nil, now)

    snapshot = %Snapshot{
      token_id: 1,
      provider_label: "Codex",
      account_label: "Account #1",
      availability: :unavailable,
      state: :fresh,
      windows: [
        %Window{label: "Primary", used_percent: 100, remaining_percent: 0, resets_at: reset}
      ]
    }

    refute LLMProxy.ProviderUsage.available_snapshot?(snapshot, now)
    assert LLMProxy.ProviderUsage.available_snapshot?(snapshot, reset)
    assert LLMProxy.ProviderUsage.available_snapshot?(%{snapshot | state: :stale}, reset)
    assert LLMProxy.ProviderUsage.available_snapshot?(%{snapshot | state: :error}, reset)
    assert LLMProxy.ProviderUsage.available_snapshot?(%{snapshot | state: :disabled}, reset)
  end

  test "waits for every exhausted usage window to reset" do
    now = DateTime.utc_now()
    first_reset = DateTime.add(now, 60, :second)
    final_reset = DateTime.add(now, 3_600, :second)

    snapshot = %Snapshot{
      token_id: 1,
      provider_label: "Codex",
      account_label: "Account #1",
      availability: :unavailable,
      state: :fresh,
      windows: [
        %Window{
          label: "Primary",
          used_percent: 100,
          remaining_percent: 0,
          resets_at: first_reset
        },
        %Window{
          label: "Secondary",
          used_percent: 100,
          remaining_percent: 0,
          resets_at: final_reset
        },
        %Window{
          label: "Available",
          used_percent: 50,
          remaining_percent: 50,
          resets_at: DateTime.add(now, 30, :second)
        }
      ]
    }

    refute LLMProxy.ProviderUsage.available_snapshot?(snapshot, first_reset)
    assert LLMProxy.ProviderUsage.available_snapshot?(snapshot, final_reset)
  end

  test "keeps authoritative exhaustion unavailable when a blocking reset is unknown" do
    snapshot = %Snapshot{
      token_id: 1,
      provider_label: "Codex",
      account_label: "Account #1",
      availability: :unavailable,
      state: :fresh,
      windows: [
        %Window{label: "Primary", used_percent: 100, remaining_percent: 0, resets_at: nil}
      ]
    }

    refute LLMProxy.ProviderUsage.available_snapshot?(snapshot, DateTime.utc_now())
  end

  test "formats and sorts dashboard rows by operational attention and remaining quota" do
    now = ~U[2026-08-24 12:00:00Z]

    available = %Snapshot{
      token_id: 1,
      provider_label: "OpenAI Codex",
      account_label: "c***n · #1",
      plan: "Plus",
      reset_credits_available: 1,
      reset_credit_expires_at: DateTime.add(now, 172_800, :second),
      availability: :available,
      state: :fresh,
      refreshed_at: now,
      windows: [
        %Window{
          label: "Weekly",
          used_percent: 25,
          remaining_percent: 75,
          resets_at: DateTime.add(now, 93_600, :second)
        }
      ]
    }

    exhausted = %Snapshot{
      token_id: 2,
      provider_label: "GLM",
      account_label: "p***t · #2",
      availability: :unavailable,
      state: :fresh,
      windows: [
        %Window{
          label: "Tokens",
          used_percent: 100,
          remaining_percent: 0,
          resets_at: DateTime.add(now, 1_800, :second)
        }
      ]
    }

    assert %{rows: [first, second], columns: columns} =
             LLMProxy.ProviderUsage.rows([available, exhausted], now)

    assert first.account == "p***t · #2"
    assert first.remaining_ratio == 0.0
    assert first.used_ratio == 1.0
    assert first.resets_in == "30m"
    assert second.plan == "Plus"
    assert second.reset_credits_available == 1
    assert second.reset_credit_expires_in == "2d 0h"
    assert second.reset_credit_expires_at == DateTime.add(now, 172_800, :second)
    assert second.remaining_ratio == 0.75
    assert second.resets_in == "1d 2h"
    assert :used_percent in columns
    assert :remaining_percent in columns
    assert :remaining_ratio in columns
    assert :resets_in in columns
    assert :reset_credits_available in columns
    assert :reset_credit_expires_in in columns
  end

  test "counts only fresh exhausted accounts as quota exhausted" do
    server_state = :sys.get_state(LLMProxy.ProviderUsage.Server)

    on_exit(fn ->
      :sys.replace_state(LLMProxy.ProviderUsage.Server, fn _state -> server_state end)
    end)

    snapshots = %{
      1 => snapshot(1, :unavailable, :fresh),
      2 => snapshot(2, :unavailable, :disabled),
      3 => snapshot(3, :unavailable, :stale),
      4 => snapshot(4, :available, :fresh)
    }

    :sys.replace_state(LLMProxy.ProviderUsage.Server, fn state ->
      %{state | snapshots: snapshots}
    end)

    assert LLMProxy.ProviderUsage.exhausted_count() == 1
  end

  test "formats near and elapsed reset times clearly" do
    now = ~U[2026-08-24 12:00:00Z]

    snapshots = [
      snapshot_with_reset(1, DateTime.add(now, 30, :second)),
      snapshot_with_reset(2, now),
      snapshot_with_reset(3, DateTime.add(now, -30, :second))
    ]

    assert %{rows: rows} = LLMProxy.ProviderUsage.rows(snapshots, now)
    assert Enum.map(rows, & &1.resets_in) == ["<1m", "now", "now"]
  end

  defp snapshot(id, availability, state) do
    %Snapshot{
      token_id: id,
      provider_label: "Provider",
      account_label: "Account ##{id}",
      availability: availability,
      state: state
    }
  end

  defp snapshot_with_reset(id, resets_at) do
    %Snapshot{
      token_id: id,
      provider_label: "Provider",
      account_label: "Account ##{id}",
      availability: :available,
      state: :fresh,
      windows: [
        %Window{
          label: "Window #{id}",
          used_percent: 0,
          remaining_percent: 100,
          resets_at: resets_at
        }
      ]
    }
  end
end
