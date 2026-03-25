defmodule LLMProxy.Protocol.AnthropicTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol.Anthropic

  describe "from_openai/1" do
    test "converts basic messages" do
      body = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ]
      }

      result = Anthropic.from_openai(body)

      assert result["model"] == "claude-sonnet-4-20250514"
      assert result["max_tokens"] == 4096
      assert [%{"role" => "user", "content" => "Hello"}] = result["messages"]
    end

    test "extracts system messages" do
      body = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [
          %{"role" => "system", "content" => "You are helpful"},
          %{"role" => "user", "content" => "Hi"}
        ]
      }

      result = Anthropic.from_openai(body)

      assert [%{"type" => "text", "text" => "You are helpful"}] = result["system"]
      assert [%{"role" => "user", "content" => "Hi"}] = result["messages"]
    end

    test "converts tool calls in assistant messages" do
      body = %{
        "model" => "m",
        "messages" => [
          %{
            "role" => "assistant",
            "content" => "Let me check",
            "tool_calls" => [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "get_weather",
                  "arguments" => ~s({"city":"London"})
                }
              }
            ]
          }
        ]
      }

      result = Anthropic.from_openai(body)
      [msg] = result["messages"]

      assert msg["role"] == "assistant"
      assert [%{"type" => "text", "text" => "Let me check"}, %{"type" => "tool_use"} = tool] = msg["content"]
      assert tool["id"] == "call_1"
      assert tool["name"] == "get_weather"
      assert tool["input"] == %{"city" => "London"}
    end

    test "converts tool result messages" do
      body = %{
        "model" => "m",
        "messages" => [
          %{
            "role" => "tool",
            "tool_call_id" => "call_1",
            "content" => "Sunny, 22°C"
          }
        ]
      }

      result = Anthropic.from_openai(body)
      [msg] = result["messages"]

      assert msg["role"] == "user"
      assert [%{"type" => "tool_result", "tool_use_id" => "call_1", "content" => "Sunny, 22°C"}] = msg["content"]
    end

    test "converts OpenAI tools to Anthropic format" do
      body = %{
        "model" => "m",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "get_weather",
              "description" => "Get weather",
              "parameters" => %{"type" => "object", "properties" => %{}}
            }
          }
        ]
      }

      result = Anthropic.from_openai(body)
      [tool] = result["tools"]

      assert tool["name"] == "get_weather"
      assert tool["description"] == "Get weather"
      assert tool["input_schema"] == %{"type" => "object", "properties" => %{}}
    end

    test "preserves temperature" do
      body = %{
        "model" => "m",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "temperature" => 0.7
      }

      result = Anthropic.from_openai(body)
      assert result["temperature"] == 0.7
    end

    test "respects max_tokens from body" do
      body = %{
        "model" => "m",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 1024
      }

      result = Anthropic.from_openai(body)
      assert result["max_tokens"] == 1024
    end
  end

  describe "extract_usage/1" do
    test "extracts all usage fields" do
      response = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 200,
          "cache_read_input_tokens" => 50,
          "cache_creation_input_tokens" => 30
        }
      }

      assert Anthropic.extract_usage(response) == %{
               input_tokens: 100,
               output_tokens: 200,
               cache_read_tokens: 50,
               cache_write_tokens: 30
             }
    end

    test "defaults missing fields to 0" do
      assert Anthropic.extract_usage(%{}) == %{
               input_tokens: 0,
               output_tokens: 0,
               cache_read_tokens: 0,
               cache_write_tokens: 0
             }
    end
  end
end
