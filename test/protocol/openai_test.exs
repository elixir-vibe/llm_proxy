defmodule LLMProxy.Protocol.OpenAITest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol.OpenAI

  describe "convert_response/3 from :anthropic" do
    test "converts text-only response" do
      response = %{
        "id" => "msg_123",
        "content" => [%{"type" => "text", "text" => "Hello world"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      result = OpenAI.convert_response(response, :anthropic, "claude-sonnet-4-20250514")

      assert result["id"] == "msg_123"
      assert result["object"] == "chat.completion"
      assert result["model"] == "claude-sonnet-4-20250514"

      [choice] = result["choices"]
      assert choice["finish_reason"] == "stop"
      assert choice["message"]["content"] == "Hello world"
      refute Map.has_key?(choice["message"], "tool_calls")
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

      result = OpenAI.convert_response(response, :anthropic, "m")

      [choice] = result["choices"]
      assert choice["finish_reason"] == "tool_calls"
      [tc] = choice["message"]["tool_calls"]
      assert tc["function"]["name"] == "get_weather"
    end

    test "maps stop reasons correctly" do
      for {anthropic, openai} <- [{"end_turn", "stop"}, {"tool_use", "tool_calls"}, {"max_tokens", "length"}] do
        response = %{"content" => [], "stop_reason" => anthropic, "usage" => %{}}
        result = OpenAI.convert_response(response, :anthropic, "m")
        [choice] = result["choices"]
        assert choice["finish_reason"] == openai
      end
    end
  end

  describe "convert_response/3 from :openai" do
    test "passes through with model set" do
      response = %{
        "id" => "chatcmpl-123",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hi"}}]
      }

      result = OpenAI.convert_response(response, :openai, "gpt-4o")
      assert result["model"] == "gpt-4o"
      assert result["id"] == "chatcmpl-123"
    end
  end

  describe "extract_usage/1" do
    test "extracts OpenAI usage" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "prompt_tokens_details" => %{"cached_tokens" => 20}
        }
      }

      assert OpenAI.extract_usage(response) == %{
               input_tokens: 100,
               output_tokens: 50,
               cache_read_tokens: 20,
               cache_write_tokens: 0
             }
    end

    test "handles missing usage" do
      assert OpenAI.extract_usage(%{}) == %{
               input_tokens: 0,
               output_tokens: 0,
               cache_read_tokens: 0,
               cache_write_tokens: 0
             }
    end
  end
end
