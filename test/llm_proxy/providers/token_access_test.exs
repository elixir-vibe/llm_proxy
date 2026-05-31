defmodule LLMProxy.Providers.TokenAccessTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{Result, TokenAccess}
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    :ok
  end

  test "pick_token/2 returns a structured error when no tokens are available" do
    assert TokenAccess.pick_token("missing", "user-1") ==
             {:error, Result.error("No available tokens: no_tokens", 503, nil)}
  end
end
