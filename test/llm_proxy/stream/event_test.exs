defmodule LLMProxy.Stream.EventTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Stream.Event
  alias LLMProxy.Usage

  test "builds OpenAI stream events with usage from wire maps" do
    event =
      Event.from_openai_map(%{
        "usage" => %{
          "prompt_tokens" => 3,
          "completion_tokens" => 2,
          "prompt_tokens_details" => %{"cached_tokens" => 1}
        }
      })

    assert event.usage == Usage.new(3, 2, 1, 0)
    assert event.kind == :usage
  end

  test "builds Responses terminal events with usage" do
    event = Event.responses_terminal(:stop, "resp_123", %{input_tokens: 2, output_tokens: 3})

    assert event.data == %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_123",
               "status" => "completed",
               "usage" => %{
                 "input_tokens" => 2,
                 "output_tokens" => 3,
                 "total_tokens" => 5,
                 "input_tokens_details" => %{"cached_tokens" => 0}
               }
             }
           }

    assert event.usage.input_tokens == 2
    assert event.usage.output_tokens == 3
    assert event.kind == :finish
  end

  test "builds OpenAI chat tool-call delta events" do
    event = Event.openai_chat_tool_call_delta(0, "call_1", "lookup", %{id: 1}, "model")

    assert [choice] = event.data["choices"]
    assert [tool_call] = choice["delta"]["tool_calls"]
    assert tool_call["id"] == "call_1"
    assert tool_call["function"] == %{"name" => "lookup", "arguments" => ~s({"id":1})}
    assert event.kind == :tool_call
    assert Event.output_delta?(event)
  end

  test "classifies OpenAI content and start events semantically" do
    content =
      Event.from_openai_map(%{
        "choices" => [%{"delta" => %{"content" => "hello"}, "finish_reason" => nil}]
      })

    start =
      Event.from_openai_map(%{
        "choices" => [%{"delta" => %{"role" => "assistant"}, "finish_reason" => nil}]
      })

    assert content.kind == :content
    assert Event.output_delta?(content)
    assert start.kind == :start
    refute Event.output_delta?(start)
  end

  test "builds OpenAI chat delta events with usage" do
    event =
      Event.openai_chat_delta("model", %{}, :incomplete, %{input_tokens: 2, output_tokens: 3})

    assert event.data["model"] == "model"
    assert [%{"finish_reason" => "length"}] = event.data["choices"]
    assert event.data["usage"]["prompt_tokens"] == 2
    assert event.usage.input_tokens == 2
  end
end
