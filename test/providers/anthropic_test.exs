defmodule LLMProxy.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Usage

  alias LLMProxy.Providers.Anthropic

  describe "to_openai_response/2" do
    test "converts text-only response" do
      response = %{
        "id" => "msg_123",
        "content" => [%{"type" => "text", "text" => "Hello world"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      result = Anthropic.to_openai_response(response, "claude-sonnet-4-20250514")

      assert result["id"] == "msg_123"
      assert result["object"] == "chat.completion"
      assert result["model"] == "claude-sonnet-4-20250514"

      [choice] = result["choices"]
      assert choice["index"] == 0
      assert choice["finish_reason"] == "stop"
      assert choice["message"]["role"] == "assistant"
      assert choice["message"]["content"] == "Hello world"
      refute Map.has_key?(choice["message"], "tool_calls")

      assert result["usage"]["prompt_tokens"] == 10
      assert result["usage"]["completion_tokens"] == 20
      assert result["usage"]["total_tokens"] == 30
    end

    test "converts tool_use response" do
      response = %{
        "id" => "msg_456",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_01",
            "name" => "get_weather",
            "input" => %{"city" => "London"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 50, "output_tokens" => 30}
      }

      result = Anthropic.to_openai_response(response, "claude-sonnet-4-20250514")

      [choice] = result["choices"]
      assert choice["finish_reason"] == "tool_calls"
      assert choice["message"]["content"] == ""

      [tool_call] = choice["message"]["tool_calls"]
      assert tool_call["id"] == "toolu_01"
      assert tool_call["type"] == "function"
      assert tool_call["function"]["name"] == "get_weather"
      assert Jason.decode!(tool_call["function"]["arguments"]) == %{"city" => "London"}
    end

    test "converts mixed text + tool_use response" do
      response = %{
        "id" => "msg_789",
        "content" => [
          %{"type" => "text", "text" => "Let me check the weather."},
          %{
            "type" => "tool_use",
            "id" => "toolu_02",
            "name" => "get_weather",
            "input" => %{"city" => "Paris"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 40, "output_tokens" => 25}
      }

      result = Anthropic.to_openai_response(response, "claude-sonnet-4-20250514")

      [choice] = result["choices"]
      assert choice["message"]["content"] == "Let me check the weather."
      assert length(choice["message"]["tool_calls"]) == 1
    end

    test "maps stop_reason end_turn to stop" do
      response = %{
        "content" => [%{"type" => "text", "text" => "Done"}],
        "stop_reason" => "end_turn",
        "usage" => %{}
      }

      [choice] = Anthropic.to_openai_response(response, "m")["choices"]
      assert choice["finish_reason"] == "stop"
    end

    test "maps stop_reason tool_use to tool_calls" do
      response = %{
        "content" => [],
        "stop_reason" => "tool_use",
        "usage" => %{}
      }

      [choice] = Anthropic.to_openai_response(response, "m")["choices"]
      assert choice["finish_reason"] == "tool_calls"
    end

    test "maps stop_reason max_tokens to length" do
      response = %{
        "content" => [%{"type" => "text", "text" => "truncated"}],
        "stop_reason" => "max_tokens",
        "usage" => %{}
      }

      [choice] = Anthropic.to_openai_response(response, "m")["choices"]
      assert choice["finish_reason"] == "length"
    end

    test "passes through unknown stop_reason" do
      response = %{
        "content" => [],
        "stop_reason" => "custom_reason",
        "usage" => %{}
      }

      [choice] = Anthropic.to_openai_response(response, "m")["choices"]
      assert choice["finish_reason"] == "custom_reason"
    end

    test "handles empty content" do
      response = %{
        "content" => [],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 0}
      }

      result = Anthropic.to_openai_response(response, "m")
      [choice] = result["choices"]
      assert choice["message"]["content"] == ""
    end

    test "handles nil content" do
      response = %{
        "stop_reason" => "end_turn",
        "usage" => %{}
      }

      result = Anthropic.to_openai_response(response, "m")
      [choice] = result["choices"]
      assert choice["message"]["content"] == ""
    end

    test "defaults id to empty string when missing" do
      response = %{"content" => [], "stop_reason" => "end_turn", "usage" => %{}}
      assert Anthropic.to_openai_response(response, "m")["id"] == ""
    end
  end

  describe "extract_usage/1" do
    test "extracts normal usage" do
      response = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 200
        }
      }

      assert Anthropic.extract_usage(response) ==
               Usage.new(100, 200)
    end

    test "extracts usage with cache tokens" do
      response = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 200,
          "cache_read_input_tokens" => 50,
          "cache_creation_input_tokens" => 30
        }
      }

      assert Anthropic.extract_usage(response) ==
               Usage.new(100, 200, 50, 30)
    end

    test "handles nil usage" do
      assert Anthropic.extract_usage(%{}) ==
               Usage.new(0, 0)
    end

    test "handles empty usage map" do
      assert Anthropic.extract_usage(%{"usage" => %{}}) ==
               Usage.new(0, 0)
    end
  end
end
