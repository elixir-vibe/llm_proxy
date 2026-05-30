defmodule LLMProxy.TokenPool.ServerTest do
  use ExUnit.Case

  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    Server.clear_rate_limits()
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
end
