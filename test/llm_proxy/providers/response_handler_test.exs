defmodule LLMProxy.Providers.ResponseHandlerTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.ResponseHandler

  describe "retry_after_ms/1" do
    test "parses retry-after seconds" do
      assert ResponseHandler.retry_after_ms(%{"retry-after" => ["3"]}) == 3_000
    end

    test "ignores unsupported retry-after values" do
      assert ResponseHandler.retry_after_ms(%{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]}) ==
               nil

      assert ResponseHandler.retry_after_ms(%{}) == nil
    end
  end

  describe "handle_response/3" do
    setup do
      LLMProxy.TestSupport.checkout_repo()
      :ok = LLMProxy.TestSupport.allow_token_pool()
      LLMProxy.TestSupport.clear_provider_tokens()
      :ok
    end

    test "marks rate-limited tokens" do
      {:ok, token} = LLMProxy.Storage.add_token("openai", "api-key", "token")

      assert {:error, %LLMProxy.Providers.Result{status: 429, token: ^token}} =
               ResponseHandler.handle_response(token, 429, %{"error" => "slow down"})
    end
  end

  describe "handle_exception/1" do
    test "wraps exceptions" do
      assert {:error, %LLMProxy.Providers.Result{status: 502, error: "boom"}} =
               ResponseHandler.handle_exception(%RuntimeError{message: "boom"})
    end
  end

  describe "extract/1" do
    test "extracts nested error message" do
      body = %{"error" => %{"message" => "Rate limit exceeded"}}
      assert ResponseHandler.extract(body) == "Rate limit exceeded"
    end

    test "extracts string error" do
      body = %{"error" => "Something went wrong"}
      assert ResponseHandler.extract(body) == "Something went wrong"
    end

    test "returns binary body as-is" do
      assert ResponseHandler.extract("raw error text") == "raw error text"
    end

    test "inspects other values" do
      body = %{"status" => "fail"}
      assert ResponseHandler.extract(body) == inspect(body)
    end

    test "inspects nil" do
      assert ResponseHandler.extract(nil) == "nil"
    end
  end
end
