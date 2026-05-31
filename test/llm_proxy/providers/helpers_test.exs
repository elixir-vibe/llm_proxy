defmodule LLMProxy.Providers.HelpersTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Usage

  alias LLMProxy.Providers.Helpers

  describe "extract_openai_usage/1" do
    test "extracts normal usage" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 150,
          "completion_tokens" => 80
        }
      }

      assert Helpers.extract_openai_usage(response) ==
               Usage.new(150, 80)
    end

    test "extracts cached_tokens from prompt_tokens_details" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 200,
          "completion_tokens" => 50,
          "prompt_tokens_details" => %{
            "cached_tokens" => 120
          }
        }
      }

      assert Helpers.extract_openai_usage(response) ==
               Usage.new(200, 50, 120, 0)
    end

    test "handles nil usage" do
      assert Helpers.extract_openai_usage(%{}) ==
               Usage.new(0, 0)
    end

    test "handles empty usage map" do
      assert Helpers.extract_openai_usage(%{"usage" => %{}}) ==
               Usage.new(0, 0)
    end

    test "cache_write_tokens is always 0" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 100,
          "prompt_tokens_details" => %{"cached_tokens" => 50}
        }
      }

      assert Helpers.extract_openai_usage(response).cache_write_tokens == 0
    end
  end

  describe "retry_after_ms/1" do
    test "parses retry-after seconds" do
      assert Helpers.retry_after_ms(%{"retry-after" => ["3"]}) == 3_000
    end

    test "ignores unsupported retry-after values" do
      assert Helpers.retry_after_ms(%{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]}) == nil
      assert Helpers.retry_after_ms(%{}) == nil
    end
  end

  describe "extract_error/1" do
    test "extracts nested error message" do
      body = %{"error" => %{"message" => "Rate limit exceeded"}}
      assert Helpers.extract_error(body) == "Rate limit exceeded"
    end

    test "extracts string error" do
      body = %{"error" => "Something went wrong"}
      assert Helpers.extract_error(body) == "Something went wrong"
    end

    test "returns binary body as-is" do
      assert Helpers.extract_error("raw error text") == "raw error text"
    end

    test "inspects other values" do
      body = %{"status" => "fail"}
      assert Helpers.extract_error(body) == inspect(body)
    end

    test "inspects nil" do
      assert Helpers.extract_error(nil) == "nil"
    end
  end
end
