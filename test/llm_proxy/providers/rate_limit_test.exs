defmodule LLMProxy.Providers.RateLimitTest do
  use ExUnit.Case

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Execution, OpenAICodex, RateLimit, Result}
  alias LLMProxy.Providers.ReqLLM, as: ConfiguredProvider
  alias LLMProxy.Schemas.ProviderTokenCooldown
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server, as: TokenPool

  defmodule LimitedProvider do
    def name, do: "limited-provider"
    def native_protocol, do: :openai
    def stream(body, user), do: call(body, user)

    def call(body, user) do
      {:ok, token} = TokenPool.pick_token("openrouter", user, body["model"])
      {:error, Result.error("throttled", 429, token, retry_after_ms: 4_000)}
    end
  end

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    TokenPool.clear_rate_limits()
    previous = Application.get_env(:llm_proxy, :providers, %{})
    Application.put_env(:llm_proxy, :providers, %{})
    on_exit(fn -> Application.put_env(:llm_proxy, :providers, previous) end)
    {:ok, token} = Storage.add_token("openrouter", "api-key", "synthetic")
    %{token: token}
  end

  test "stream establishment records the same cooldown and retry hint as buffered execution" do
    request = %Request{
      protocol: :openai_chat,
      model: "formatter",
      body: %{"messages" => []},
      messages: []
    }

    assert {:error, %{retry_after_ms: 4_000}} =
             Execution.stream(LimitedProvider, request, "user", "formatter")

    assert [%{scope: "model"}] = Repo.all(ProviderTokenCooldown)
    assert {:error, :all_rate_limited} = TokenPool.pick_token("openrouter", "user", "formatter")
  end

  test "late stream errors preserve retry headers inside wrapped causes", %{token: token} do
    cause = %ReqLLM.Error.API.Request{
      status: 429,
      headers: %{"retry-after" => ["8"]},
      response_body: %{"error" => %{"message" => "throttled"}}
    }

    error = %ReqLLM.Error.API.Stream{cause: cause}

    result =
      Result.stream_failure(ConfiguredProvider, "formatter", token, error, "openrouter")

    assert result.retry_after_ms == 8_000
    assert [%{scope: "model"}] = Repo.all(ProviderTokenCooldown)
  end

  test "ordinary API 429 has a short model cooldown and leaves other models usable", %{
    token: token
  } do
    result = RateLimit.record(%{Result.error("throttled", 429, token) | model: "formatter"})
    assert result.retry_after_ms == 30_000
    assert [%{scope: "model"}] = Repo.all(ProviderTokenCooldown)
    assert {:error, :all_rate_limited} = TokenPool.pick_token("openrouter", "user", "formatter")
    assert {:ok, _} = TokenPool.pick_token("openrouter", "user", "assessment")
  end

  test "configured provider identity wins over a shared credential pool", %{token: token} do
    Application.put_env(:llm_proxy, :providers, %{
      "custom-endpoint" => %{rate_limit_cooldown_ms: 7_000},
      "openrouter" => %{rate_limit_cooldown_ms: 90_000}
    })

    result =
      RateLimit.record(%{
        Result.error("throttled", 429, token)
        | provider_name: "custom-endpoint",
          model: "formatter"
      })

    assert result.retry_after_ms == 7_000
  end

  test "explicit retry hint takes precedence over provider fallback", %{token: token} do
    result =
      RateLimit.record(%{
        Result.error("throttled", 429, token, retry_after_ms: 2_000)
        | model: "formatter"
      })

    assert result.retry_after_ms == 2_000
    assert [%ProviderTokenCooldown{}] = Repo.all(ProviderTokenCooldown)
  end

  test "Retry-After zero does not persist a cooldown", %{token: token} do
    assert %{retry_after_ms: 0} =
             RateLimit.record(%{
               Result.error("throttled", 429, token, retry_after_ms: 0)
               | model: "formatter"
             })

    assert Repo.all(ProviderTokenCooldown) == []
  end

  test "Codex transient 429 does not inherit subscription quota cooldown" do
    {:ok, token} = Storage.add_token("openai-codex", "oauth", "synthetic")
    error = %{status: 429, response_body: %{"error" => %{"type" => "rate_limit_exceeded"}}}
    result = Result.stream_failure(OpenAICodex, "model-a", token, error)
    assert result.retry_after_ms == 30_000
    assert result.rate_limit_kind == :throttle
    assert [%{scope: "model"}] = Repo.all(ProviderTokenCooldown)
  end

  test "explicit Codex quota uses its separate configurable account cooldown" do
    Application.put_env(:llm_proxy, :providers, %{"openai-codex" => %{quota_cooldown_ms: 90_000}})
    {:ok, token} = Storage.add_token("openai-codex", "oauth", "synthetic")
    error = {:websocket_error_event, %{"error" => %{"type" => "usage_limit_reached"}}}
    result = Result.stream_failure(OpenAICodex, "model-a", token, error)
    assert result.status == 429
    assert result.retry_after_ms == 90_000
    assert result.rate_limit_kind == :quota
    assert [%{scope: "account"}] = Repo.all(ProviderTokenCooldown)
    assert {:error, :all_rate_limited} = TokenPool.pick_token("openai-codex", "user", "model-b")
  end

  test "ordinary API failures do not clear or shorten an existing quota block", %{token: token} do
    {:ok, saved} = TokenPool.mark_rate_limited(token, 14_400_000)
    RateLimit.record(%{Result.error("throttled", 429, token) | model: "formatter"})
    assert Repo.get(ProviderTokenCooldown, saved.id).available_at == saved.available_at
  end

  test "authentication and billing errors do not create temporary cooldowns", %{token: token} do
    for status <- [401, 402, 403] do
      result = Result.error("provider refused", status, token)
      assert RateLimit.record(result) == result
    end

    assert Repo.all(ProviderTokenCooldown) == []
  end

  test "insufficient API credits remain an error without an invented reset", %{token: token} do
    result =
      ConfiguredProvider.stream_error(
        %{
          status: 429,
          response_body: %{"code" => "insufficient_quota", "message" => "No credits"}
        },
        token,
        "formatter"
      )

    assert result.rate_limit_kind == :none

    assert RateLimit.record(result) == result
    assert Repo.all(ProviderTokenCooldown) == []
  end

  test "Codex quota classification uses explicit code even with a generic error type" do
    {:ok, token} = Storage.add_token("openai-codex", "oauth", "synthetic")

    reason = %{
      status: 429,
      response_body: %{"error" => %{"code" => "usage_limit_reached", "type" => "quota_error"}}
    }

    result = Result.stream_failure(OpenAICodex, "model", token, reason)
    assert result.rate_limit_kind == :quota
    assert result.retry_after_ms == 14_400_000
  end

  test "parses seconds and HTTP dates with an explicit clock" do
    now = DateTime.to_unix(~U[2026-10-01 20:00:00Z], :millisecond)
    assert RateLimit.retry_after_ms(%{"Retry-After" => ["3"]}, now) == 3_000

    assert RateLimit.retry_after_ms(%{"retry-after" => "Thu, 01 Oct 2026 20:00:30 GMT"}, now) ==
             30_000

    assert RateLimit.retry_after_ms([{"Retry-After", "Thu, 01 Oct 2026 19:59:00 GMT"}], now) == 0

    for value <- ["garbage", "-1", "1.5", "99999999999999999"] do
      assert RateLimit.retry_after_ms(%{"retry-after" => [value]}, now) == nil
    end
  end
end
