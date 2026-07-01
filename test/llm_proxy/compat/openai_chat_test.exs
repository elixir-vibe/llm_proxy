defmodule LLMProxy.Compat.OpenAIChatTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol.{OpenAI, Request}

  test "round-trips assistant tool calls and tool results through normalized requests" do
    body = %{
      "model" => "gpt-4o",
      "messages" => [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call_weather",
              "type" => "function",
              "function" => %{"name" => "weather", "arguments" => ~s({"city":"Paris"})}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "call_weather", "content" => "sunny"}
      ]
    }

    assert {:ok, request} = Request.parse(:openai_chat, body)
    rendered = OpenAI.request_body(request)

    assert [assistant, tool] = rendered["messages"]
    assert assistant["content"] == nil
    assert get_in(assistant, ["tool_calls", Access.at(0), "id"]) == "call_weather"

    assert get_in(assistant, ["tool_calls", Access.at(0), "function", "arguments"]) ==
             ~s({"city":"Paris"})

    assert tool == %{"role" => "tool", "tool_call_id" => "call_weather", "content" => "sunny"}
  end

  test "preserves OpenAI-specific structured output options at the wire boundary" do
    body = %{
      "model" => "gpt-4o",
      "messages" => [%{"role" => "user", "content" => "json please"}],
      "parallel_tool_calls" => false,
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{"name" => "answer", "schema" => %{"type" => "object"}}
      },
      "provider" => %{"order" => ["OpenAI"], "allow_fallbacks" => false},
      "transforms" => ["middle-out"],
      "reasoning" => %{"effort" => "low"},
      "include_reasoning" => true,
      "max_completion_tokens" => 123
    }

    assert {:ok, request} = Request.parse(:openai_chat, body)
    rendered = OpenAI.request_body(request)

    assert rendered["parallel_tool_calls"] == false
    assert rendered["response_format"] == body["response_format"]
    assert rendered["provider"] == body["provider"]
    assert rendered["transforms"] == body["transforms"]
    assert rendered["reasoning"] == body["reasoning"]
    assert rendered["include_reasoning"] == true
    assert rendered["max_completion_tokens"] == 123
  end

  test "preserves image detail hints when parsing and rendering OpenAI image content" do
    body = %{
      "model" => "gpt-4o",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "image_url",
              "image_url" => %{"url" => "https://example.test/a.png", "detail" => "high"}
            }
          ]
        }
      ]
    }

    assert {:ok, request} = Request.parse(:openai_chat, body)
    assert [message] = request.messages
    assert [part] = message.content
    assert part.metadata == %{"detail" => "high"}

    assert %{"messages" => [%{"content" => [%{"image_url" => image}]}]} =
             OpenAI.request_body(request)

    assert image == %{"url" => "https://example.test/a.png", "detail" => "high"}
  end

  test "converts Anthropic text/tool/text responses to OpenAI message shape" do
    response = %{
      "id" => "msg_123",
      "content" => [
        %{"type" => "text", "text" => "Let me check."},
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => %{"id" => 1}},
        %{"type" => "text", "text" => "Done."}
      ],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 3, "output_tokens" => 4}
    }

    converted = OpenAI.convert_response(response, :anthropic, "claude")
    [choice] = converted["choices"]

    assert choice["message"]["content"] == "Let me check.\nDone."
    assert choice["finish_reason"] == "tool_calls"

    assert get_in(choice, ["message", "tool_calls", Access.at(0), "function", "arguments"]) ==
             ~s({"id":1})
  end
end
