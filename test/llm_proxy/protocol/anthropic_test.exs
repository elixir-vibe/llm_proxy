defmodule LLMProxy.Protocol.AnthropicTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Usage

  alias LLMProxy.Protocol.{Anthropic, Request}

  describe "request_body/1" do
    test "converts basic messages" do
      body = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ]
      }

      result = body |> request() |> Anthropic.request_body()

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

      result = body |> request() |> Anthropic.request_body()

      assert result["system"] == "You are helpful"
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

      result = body |> request() |> Anthropic.request_body()
      [msg] = result["messages"]

      assert msg["role"] == "assistant"

      assert [%{"type" => "text", "text" => "Let me check"}, %{"type" => "tool_use"} = tool] =
               msg["content"]

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

      result = body |> request() |> Anthropic.request_body()
      [msg] = result["messages"]

      assert msg["role"] == "user"

      assert [%{"type" => "tool_result", "tool_use_id" => "call_1", "content" => "Sunny, 22°C"}] =
               msg["content"]
    end

    test "converts image_url content" do
      body = %{
        "model" => "m",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "look"},
              %{"type" => "image_url", "image_url" => %{"url" => "https://example.test/a.png"}}
            ]
          }
        ]
      }

      result = body |> request() |> Anthropic.request_body()
      [message] = result["messages"]

      assert message["content"] == [
               %{"type" => "text", "text" => "look"},
               %{
                 "type" => "image",
                 "source" => %{"type" => "url", "url" => "https://example.test/a.png"}
               }
             ]
    end

    test "preserves Anthropic thinking blocks" do
      body = %{
        "model" => "m",
        "messages" => [
          %{
            "role" => "assistant",
            "content" => [%{"type" => "thinking", "thinking" => "considering"}]
          }
        ]
      }

      result = body |> request(:anthropic_messages) |> Anthropic.request_body()
      [message] = result["messages"]

      assert message["content"] == [%{"type" => "thinking", "thinking" => "considering"}]
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

      result = body |> request() |> Anthropic.request_body()
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

      result = body |> request() |> Anthropic.request_body()
      assert result["temperature"] == 0.7
    end

    test "respects max_tokens from body" do
      body = %{
        "model" => "m",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 1024
      }

      result = body |> request() |> Anthropic.request_body()
      assert result["max_tokens"] == 1024
    end
  end

  describe "convert_response/3" do
    test "converts openai responses to anthropic format" do
      response = %{
        "id" => "resp_1",
        "choices" => [
          %{
            "message" => %{
              "content" => "Done",
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "function" => %{"name" => "lookup", "arguments" => ~s({"id":1})}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 7}
      }

      result = Anthropic.convert_response(response, :openai, "claude-sonnet-4")

      assert result["id"] == "resp_1"
      assert result["model"] == "claude-sonnet-4"
      assert result["stop_reason"] == "tool_use"
      assert result["usage"] == %{"input_tokens" => 11, "output_tokens" => 7}
      assert Enum.any?(result["content"], &(&1["type"] == "text" and &1["text"] == "Done"))
      assert Enum.any?(result["content"], &(&1["type"] == "tool_use" and &1["id"] == "call_1"))
    end

    test "returns anthropic responses unchanged for anthropic target" do
      response = %{"id" => "msg_1"}
      assert Anthropic.convert_response(response, :anthropic, "claude") == response
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

      assert Anthropic.extract_usage(response) ==
               Usage.new(100, 200, 50, 30)
    end

    test "defaults missing fields to 0" do
      assert Anthropic.extract_usage(%{}) ==
               Usage.new(0, 0)
    end
  end

  defp request(body, protocol \\ :openai_chat) do
    {:ok, request} = Request.parse(protocol, body)
    request
  end
end
