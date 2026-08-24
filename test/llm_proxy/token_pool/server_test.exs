defmodule LLMProxy.TokenPool.ServerTest do
  use ExUnit.Case

  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server

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

  defp restore_env(key, nil), do: Application.delete_env(:llm_proxy, key)
  defp restore_env(key, value), do: Application.put_env(:llm_proxy, key, value)
end
