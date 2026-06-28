defmodule LLMProxy.Providers.ProviderErrorTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.ProviderError

  describe "retry_after_ms/1" do
    test "parses retry-after seconds" do
      assert ProviderError.retry_after_ms(%{"retry-after" => ["3"]}) == 3_000
    end

    test "ignores unsupported retry-after values" do
      assert ProviderError.retry_after_ms(%{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]}) ==
               nil

      assert ProviderError.retry_after_ms(%{}) == nil
    end
  end

  describe "extract/1" do
    test "extracts nested error message" do
      body = %{"error" => %{"message" => "Rate limit exceeded"}}
      assert ProviderError.extract(body) == "Rate limit exceeded"
    end

    test "extracts string error" do
      body = %{"error" => "Something went wrong"}
      assert ProviderError.extract(body) == "Something went wrong"
    end

    test "returns binary body as-is" do
      assert ProviderError.extract("raw error text") == "raw error text"
    end

    test "inspects other values" do
      body = %{"status" => "fail"}
      assert ProviderError.extract(body) == inspect(body)
    end

    test "inspects nil" do
      assert ProviderError.extract(nil) == "nil"
    end
  end
end
