defmodule LLMProxy.Providers.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.OpenAICompatible
  alias LLMProxy.Usage

  describe "extract_usage/1" do
    test "extracts normal usage" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 150,
          "completion_tokens" => 80
        }
      }

      assert OpenAICompatible.extract_usage(response) == Usage.new(150, 80)
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

      assert OpenAICompatible.extract_usage(response) == Usage.new(200, 50, 120, 0)
    end

    test "handles nil usage" do
      assert OpenAICompatible.extract_usage(%{}) == Usage.new(0, 0)
    end

    test "handles empty usage map" do
      assert OpenAICompatible.extract_usage(%{"usage" => %{}}) == Usage.new(0, 0)
    end

    test "cache_write_tokens is always 0" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 100,
          "prompt_tokens_details" => %{"cached_tokens" => 50}
        }
      }

      assert OpenAICompatible.extract_usage(response).cache_write_tokens == 0
    end
  end
end
