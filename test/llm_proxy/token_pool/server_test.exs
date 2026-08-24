defmodule LLMProxy.TokenPool.ServerTest do
  use ExUnit.Case

  alias LLMProxy.Providers.Result
  alias LLMProxy.ProviderUsage.Snapshot
  alias LLMProxy.Schemas.ProviderTokenCooldown
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Cooldown
  alias LLMProxy.TokenPool.Server
  alias ReqLLM.Error.API.Request, as: APIRequestError

  setup do
    original_strategy = Application.get_env(:llm_proxy, :token_selection_strategy)

    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    Server.clear_rate_limits()

    on_exit(fn -> restore_env(:token_selection_strategy, original_strategy) end)

    :ok
  end

  test "prefers oauth tokens over api keys" do
    {:ok, oauth} = Storage.add_token("anthropic", "oauth", "oauth-token")
    {:ok, _api_key} = Storage.add_token("anthropic", "api-key", "api-token")

    assert {:ok, picked} = Server.pick_token("anthropic", "user-1")
    assert picked.id == oauth.id
  end

  test "falls back to api keys when oauth tokens are unavailable" do
    {:ok, api_key} = Storage.add_token("openai", "api-key", "api-token")

    assert {:ok, picked} = Server.pick_token("openai", "user-1")
    assert picked.id == api_key.id
  end

  test "returns an error when no tokens exist" do
    assert {:error, :no_tokens} = Server.pick_token("missing", "user-1")
  end

  test "skips rate-limited tokens" do
    {:ok, first} = Storage.add_token("openrouter", "api-key", "token-a")
    {:ok, second} = Storage.add_token("openrouter", "api-key", "token-b")

    Server.mark_rate_limited(first)

    assert {:ok, picked} = Server.pick_token("openrouter", "user-1")
    assert picked.id == second.id
  end

  test "clear_rate_limits/0 makes all tokens available again" do
    {:ok, token} = Storage.add_token("openrouter", "api-key", "token-a")

    Server.mark_rate_limited(token)
    assert {:error, :all_rate_limited} = Server.pick_token("openrouter", "user-1")

    Server.clear_rate_limits()
    assert {:ok, picked} = Server.pick_token("openrouter", "user-1")
    assert picked.id == token.id
  end

  test "pick_token_by_kind/3 respects the requested kind" do
    {:ok, oauth} = Storage.add_token("anthropic", "oauth", "oauth-token")
    {:ok, api_key} = Storage.add_token("anthropic", "api-key", "api-token")

    assert {:ok, picked_oauth} = Server.pick_token_by_kind("anthropic", "oauth", "user-1")
    assert picked_oauth.id == oauth.id

    assert {:ok, picked_api_key} = Server.pick_token_by_kind("anthropic", "api-key", "user-1")
    assert picked_api_key.id == api_key.id
  end

  test "affinity remains the default and preserves ID-based pool order" do
    {:ok, first} = Storage.add_token("openai-codex", "oauth", "first", %{priority: 10})

    {:ok, _higher_priority} =
      Storage.add_token("openai-codex", "oauth", "second", %{priority: 20})

    assert {:ok, picked} = Server.pick_token("openai-codex", "user-1")
    assert picked.id == first.id
  end

  test "fill-first picks the highest-priority enabled token deterministically" do
    Application.put_env(:llm_proxy, :token_selection_strategy, :fill_first)

    {:ok, lower_priority} =
      Storage.add_token("openai-codex", "oauth", "lower-priority", %{priority: 10})

    {:ok, higher_priority} =
      Storage.add_token("openai-codex", "oauth", "higher-priority", %{priority: 20})

    {:ok, same_priority} =
      Storage.add_token("openai-codex", "oauth", "same-priority", %{priority: 20})

    {:ok, disabled} =
      Storage.add_token("openai-codex", "oauth", "disabled", %{priority: 30, enabled: false})

    assert {:ok, picked} = Server.pick_token("openai-codex", "user-1")
    assert picked.id == higher_priority.id
    refute picked.id in [lower_priority.id, same_priority.id, disabled.id]

    assert {:ok, same_pick} = Server.pick_token("openai-codex", "another-user")
    assert same_pick.id == higher_priority.id
  end

  test "fill-first fails over during cooldown and restores priority after recovery" do
    Application.put_env(:llm_proxy, :token_selection_strategy, :fill_first)

    {:ok, primary} = Storage.add_token("openai-codex", "oauth", "primary", %{priority: 20})
    {:ok, fallback} = Storage.add_token("openai-codex", "oauth", "fallback", %{priority: 10})

    Server.mark_rate_limited(primary, 25)

    assert {:ok, picked} = Server.pick_token("openai-codex", "user-1")
    assert picked.id == fallback.id

    Process.sleep(30)

    assert {:ok, recovered} = Server.pick_token("openai-codex", "user-1")
    assert recovered.id == primary.id
  end

  test "model cooldown does not block the same account for other models" do
    {:ok, _first} = Storage.add_token("openai-codex", "oauth", "first")
    {:ok, _second} = Storage.add_token("openai-codex", "oauth", "second")

    assert {:ok, preferred} = Server.pick_token("openai-codex", "user-1", "model-b")

    Server.mark_rate_limited(preferred, "model-a", 60_000)

    assert {:ok, %{id: id}} = Server.pick_token("openai-codex", "user-1", "model-a")
    refute id == preferred.id

    assert {:ok, %{id: id}} = Server.pick_token("openai-codex", "user-1", "model-b")
    assert id == preferred.id

    assert [%ProviderTokenCooldown{scope: "model", model_key: model_key}] =
             Repo.all(ProviderTokenCooldown)

    assert byte_size(model_key) == 64
    refute model_key =~ "model-a"
  end

  test "literal star model cooldown cannot become account-wide" do
    {:ok, preferred} = Storage.add_token("openai-codex", "oauth", "first")
    {:ok, fallback} = Storage.add_token("openai-codex", "oauth", "second")

    Server.mark_rate_limited(preferred, "*", 60_000)

    assert {:ok, %{id: id}} = Server.pick_token("openai-codex", "user-1", "*")
    assert id == fallback.id

    assert {:ok, %{id: id}} = Server.pick_token("openai-codex", "user-1", "another-model")
    assert id == preferred.id
  end

  test "rejects malformed cooldown contracts" do
    {:ok, token} = Storage.add_token("openai-codex", "oauth", "first")

    assert_raise ArgumentError, fn -> Server.mark_rate_limited(token, "bad\nmodel", 60_000) end
    assert_raise ArgumentError, fn -> Server.mark_rate_limited(token, "model", 0) end
    assert_raise ArgumentError, fn -> Server.pick_token("openai-codex", "user-1", "") end
  end

  test "a shorter concurrent cooldown cannot reduce the persisted deadline" do
    {:ok, token} = Storage.add_token("openai-codex", "oauth", "first")

    Server.mark_rate_limited(token, "model", 60_000)
    [first] = Repo.all(ProviderTokenCooldown)

    Server.mark_rate_limited(token, "model", 1)
    [second] = Repo.all(ProviderTokenCooldown)

    assert DateTime.compare(second.available_at, first.available_at) in [:eq, :gt]
  end

  test "new cooldowns prune expired persistence rows" do
    {:ok, token} = Storage.add_token("openai-codex", "oauth", "first")

    Server.mark_rate_limited(token, "expired-model", 1)
    Process.sleep(5)
    Server.mark_rate_limited(token, "active-model", 60_000)

    assert [%ProviderTokenCooldown{scope: "model", model_key: model_key}] =
             Repo.all(ProviderTokenCooldown)

    assert model_key == Cooldown.model_key!("active-model")
  end

  test "ReqLLM streaming 429 cooldown remains model-specific" do
    {:ok, token} = Storage.add_token("req-provider", "api-key", "first")

    reason =
      APIRequestError.exception(
        reason: "rate limited",
        status: 429,
        response_body: %{"message" => "slow down"},
        headers: [],
        retryable: true
      )

    result = Result.stream_failure(LLMProxy.Providers.ReqLLM, "model-a", token, reason)
    assert result.status == 429

    assert {:error, :all_rate_limited} =
             Server.pick_token("req-provider", "user-1", "model-a")

    assert {:ok, %{id: id}} = Server.pick_token("req-provider", "user-1", "model-b")
    assert id == token.id
  end

  test "selection skips an account with authoritative exhausted usage" do
    {:ok, _first} = Storage.add_token("openai-codex", "oauth", "first")
    {:ok, _second} = Storage.add_token("openai-codex", "oauth", "second")
    assert {:ok, preferred} = Server.pick_token("openai-codex", "user-1", "codex-model")
    usage_state = :sys.get_state(LLMProxy.ProviderUsage.Server)

    snapshot = %Snapshot{
      token_id: preferred.id,
      provider_label: "Codex",
      account_label: "Account ##{preferred.id}",
      availability: :unavailable,
      state: :fresh
    }

    :sys.replace_state(LLMProxy.ProviderUsage.Server, fn state ->
      %{state | snapshots: %{preferred.id => snapshot}}
    end)

    on_exit(fn -> :sys.replace_state(LLMProxy.ProviderUsage.Server, fn _ -> usage_state end) end)

    assert {:ok, %{id: id}} = Server.pick_token("openai-codex", "user-1", "codex-model")
    refute id == preferred.id
  end

  test "cooldown remains active after the token-pool server restarts" do
    {:ok, token} = Storage.add_token("openrouter", "api-key", "token-a")
    Server.mark_rate_limited(token, 60_000)

    :ok = Supervisor.terminate_child(LLMProxy.Supervisor, Server)
    {:ok, _pid} = Supervisor.restart_child(LLMProxy.Supervisor, Server)
    :ok = TestSupport.allow_token_pool()

    assert {:error, :all_rate_limited} = Server.pick_token("openrouter", "user-1")
  end

  defp restore_env(key, nil), do: Application.delete_env(:llm_proxy, key)
  defp restore_env(key, value), do: Application.put_env(:llm_proxy, key, value)
end
