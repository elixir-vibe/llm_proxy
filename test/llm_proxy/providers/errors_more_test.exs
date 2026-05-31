defmodule LLMProxy.Providers.ErrorsMoreTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{Errors, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    :ok
  end

  test "handle_response/3 marks rate-limited tokens" do
    {:ok, token} = Storage.add_token("openai", "api-key", "token")

    assert {:error, %Result{status: 429, token: ^token}} =
             Errors.handle_response(token, 429, %{"error" => "slow down"})
  end

  test "handle_exception/1 wraps exceptions" do
    assert {:error, %Result{status: 502, error: "boom"}} =
             Errors.handle_exception(%RuntimeError{message: "boom"})
  end
end
