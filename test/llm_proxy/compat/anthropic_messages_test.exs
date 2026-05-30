defmodule LLMProxy.Compat.AnthropicMessagesTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol.{Anthropic, Request}

  test "renders OpenAI assistant tool calls and tool results as Anthropic content blocks" do
    body = %{
      "model" => "claude-3-haiku-20240307",
      "messages" => [
        %{
          "role" => "assistant",
          "content" => "Checking",
          "tool_calls" => [
            %{"id" => "call_1", "function" => %{"name" => "lookup", "arguments" => ~s({"id":1})}}
          ]
        },
        %{"role" => "tool", "tool_call_id" => "call_1", "content" => "result"}
      ]
    }

    assert {:ok, request} = Request.parse(:openai_chat, body)
    rendered = Anthropic.request_body(request)

    assert [assistant, tool_result] = rendered["messages"]

    assert Enum.any?(
             assistant["content"],
             &(&1["type"] == "tool_use" and &1["input"] == %{"id" => 1})
           )

    assert tool_result == %{
             "role" => "user",
             "content" => [
               %{"type" => "tool_result", "tool_use_id" => "call_1", "content" => "result"}
             ]
           }
  end

  test "parses multiple Anthropic tool_result blocks into one normalized tool result" do
    body = %{
      "model" => "claude",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "line one"},
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_1",
              "content" => [%{"type" => "text", "text" => "line two"}]
            }
          ]
        }
      ]
    }

    assert {:ok, request} = Request.parse(:anthropic_messages, body)
    assert [message] = request.messages
    assert message.role == :tool
    assert message.tool_call_id == "toolu_1"
    assert Enum.map(message.content, & &1.text) == ["line one", "line two"]
  end

  test "preserves Anthropic thinking signatures and redacted thinking blocks" do
    body = %{
      "model" => "claude",
      "messages" => [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "thinking", "thinking" => "private", "signature" => "sig_123"},
            %{"type" => "redacted_thinking", "data" => "opaque"}
          ]
        }
      ]
    }

    assert {:ok, request} = Request.parse(:anthropic_messages, body)
    assert %{"messages" => [%{"content" => rendered}]} = Anthropic.request_body(request)

    assert rendered == [
             %{"type" => "thinking", "thinking" => "private", "signature" => "sig_123"},
             %{"type" => "redacted_thinking", "data" => "opaque"}
           ]
  end

  test "rejects malformed tool calls with structured request errors" do
    assert {:error, %Request.Error{code: "invalid_tool_call"}} =
             Request.parse(:openai_chat, %{
               "model" => "gpt-4o",
               "messages" => [
                 %{
                   "role" => "assistant",
                   "content" => nil,
                   "tool_calls" => [%{"id" => "call_1", "function" => %{"name" => "lookup"}}]
                 }
               ]
             })
  end
end
