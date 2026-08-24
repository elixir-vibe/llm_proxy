defmodule LLMProxy.ProviderUsageTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias LLMProxy.Provider.TokenCodec.AESGCM
  alias LLMProxy.ProviderUsage.{Loader, Snapshot, Source, Window}
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
            "rate_limit" => %{
              "allowed" => true,
              "primary_window" => %{
                "used_percent" => 25,
                "limit_window_seconds" => 18_000,
                "reset_at" => 1_800_000_000
              }
            }
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
end
