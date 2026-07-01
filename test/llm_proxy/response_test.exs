defmodule LLMProxy.ResponseTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Response
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  test "renders ReqLLM response as OpenAI chat completion" do
    response = %ReqLLM.Response{
      id: "resp_123",
      model: "model",
      context: %ReqLLM.Context{},
      message: %Message{role: :assistant, content: [ContentPart.text("hello")]},
      finish_reason: :stop,
      usage: %{input_tokens: 2, output_tokens: 3}
    }

    assert Response.to_openai_chat_completion(
             response,
             "model",
             "chatcmpl_resp_123",
             response.usage,
             nil,
             123
           ) == %{
             "id" => "chatcmpl_resp_123",
             "object" => "chat.completion",
             "created" => 123,
             "model" => "model",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{"role" => "assistant", "content" => "hello"},
                 "finish_reason" => "stop"
               }
             ],
             "usage" => %{
               "prompt_tokens" => 2,
               "completion_tokens" => 3,
               "total_tokens" => 5,
               "prompt_tokens_details" => %{"cached_tokens" => 0}
             }
           }
  end

  test "passes through OpenAI-compatible provider responses without dropping provider fields" do
    provider_response = %{
      "id" => "gen_123",
      "object" => "chat.completion",
      "created" => 123,
      "model" => "openai/gpt-5-mini-2025-08-07",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => ~s({"order_id":"11842","status":"ok"}),
            "reasoning" => "checked schema",
            "reasoning_details" => [%{"type" => "reasoning.text", "text" => "checked schema"}],
            "refusal" => nil
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 55,
        "completion_tokens" => 113,
        "total_tokens" => 168,
        "completion_tokens_details" => %{"reasoning_tokens" => 64},
        "cost" => 0.00023975
      }
    }

    response = %Response{
      message: %ReqLLM.Response{
        id: "gen_123",
        model: "openai/gpt-5-mini",
        context: %ReqLLM.Context{},
        message: %Message{
          role: :assistant,
          content: [ContentPart.text(~s({"order_id":"11842","status":"ok"}))]
        },
        finish_reason: :stop,
        usage: %{input_tokens: 55, output_tokens: 113}
      },
      provider_response: provider_response,
      provider: LLMProxy.Providers.OpenRouter,
      model: "openai/gpt-5-mini",
      request: %LLMProxy.Protocol.Request{}
    }

    rendered = Response.to_openai(response)
    [choice] = rendered["choices"]

    assert rendered["id"] == "gen_123"
    assert rendered["created"] == 123
    assert rendered["model"] == "openai/gpt-5-mini"
    assert choice["message"]["reasoning"] == "checked schema"

    assert choice["message"]["reasoning_details"] == [
             %{"type" => "reasoning.text", "text" => "checked schema"}
           ]

    assert Map.has_key?(choice["message"], "refusal")
    assert rendered["usage"]["completion_tokens_details"] == %{"reasoning_tokens" => 64}
    assert rendered["usage"]["cost"] == 0.00023975
  end

  test "guardrail text updates OpenAI-compatible provider response" do
    response = %Response{
      message: %ReqLLM.Response{
        id: "gen_123",
        model: "model",
        context: %ReqLLM.Context{},
        message: %Message{role: :assistant, content: [ContentPart.text("original")]},
        finish_reason: :stop,
        usage: nil
      },
      provider_response: %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "original",
              "tool_calls" => [%{"id" => "call_1"}]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      },
      provider: LLMProxy.Providers.OpenRouter,
      model: "model",
      request: %LLMProxy.Protocol.Request{}
    }

    rendered = response |> Response.put_text("redacted") |> Response.to_openai()
    message = get_in(rendered, ["choices", Access.at(0), "message"])

    assert message["content"] == "redacted"
    refute Map.has_key?(message, "tool_calls")
  end

  test "renders ReqLLM response as Responses API response" do
    tool_call = ReqLLM.ToolCall.new("call_123", "lookup", ~s({"id":1}))

    response = %ReqLLM.Response{
      id: "resp_123",
      model: "model",
      context: %ReqLLM.Context{},
      message: %Message{
        role: :assistant,
        content: [ContentPart.text("hello")],
        tool_calls: [tool_call]
      },
      finish_reason: :stop,
      usage: %{input_tokens: 2, output_tokens: 3}
    }

    assert Response.to_responses(response, "model", 123) == %{
             "id" => "resp_123",
             "object" => "response",
             "created_at" => 123,
             "model" => "model",
             "status" => "completed",
             "output" => [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "hello", "annotations" => []}],
                 "status" => "completed"
               },
               %{
                 "type" => "function_call",
                 "id" => "call_123",
                 "call_id" => "call_123",
                 "name" => "lookup",
                 "arguments" => ~s({"id":1})
               }
             ],
             "usage" => %{
               "input_tokens" => 2,
               "output_tokens" => 3,
               "total_tokens" => 5,
               "input_tokens_details" => %{"cached_tokens" => 0}
             }
           }
  end

  test "renders incomplete finish reason as OpenAI length finish reason" do
    response = %ReqLLM.Response{
      id: "resp_123",
      model: "model",
      context: %ReqLLM.Context{},
      message: %Message{role: :assistant, content: []},
      finish_reason: :incomplete,
      usage: nil
    }

    completion =
      Response.to_openai_chat_completion(response, "model", "chatcmpl_resp_123", nil, nil)

    assert get_in(completion, ["choices", Access.at(0), "finish_reason"]) == "length"
    assert get_in(completion, ["choices", Access.at(0), "message", "content"]) == nil
  end
end
