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
