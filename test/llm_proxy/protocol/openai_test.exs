defmodule LLMProxy.Protocol.OpenAITest do
  use ExUnit.Case, async: true

  alias LLMProxy.Usage

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
      for {anthropic, openai} <- [
            {"end_turn", "stop"},
            {"tool_use", "tool_calls"},
            {"max_tokens", "length"}
          ] do
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

  describe "stream_event/3" do
    test "passes openai stream events through" do
      event = %{"id" => "chunk_1"}
      assert OpenAI.stream_event(event, :openai, "gpt-4o") == event
    end

    test "converts anthropic text deltas to openai chunks" do
      event = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "hello"}
      }

      chunk = OpenAI.stream_event(event, :anthropic, "claude")

      assert chunk["object"] == "chat.completion.chunk"
      assert chunk["model"] == "claude"
      assert get_in(chunk, ["choices", Access.at(0), "delta", "content"]) == "hello"
      assert get_in(chunk, ["choices", Access.at(0), "finish_reason"]) == nil
    end

    test "converts anthropic tool deltas to openai chunks" do
      start = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup"}
      }

      delta = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"id")}
      }

      start_chunk = OpenAI.stream_event(start, :anthropic, "claude")
      delta_chunk = OpenAI.stream_event(delta, :anthropic, "claude")

      assert get_in(start_chunk, [
               "choices",
               Access.at(0),
               "delta",
               "tool_calls",
               Access.at(0),
               "id"
             ]) ==
               "toolu_1"

      assert get_in(delta_chunk, [
               "choices",
               Access.at(0),
               "delta",
               "tool_calls",
               Access.at(0),
               "function",
               "arguments"
             ]) ==
               ~s({"id")
    end

    test "converts anthropic finish reasons" do
      event = %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
      chunk = OpenAI.stream_event(event, :anthropic, "claude")
      assert get_in(chunk, ["choices", Access.at(0), "finish_reason"]) == "stop"
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

      assert OpenAI.extract_usage(response) ==
               Usage.new(100, 50, 20, 0)
    end

    test "handles missing usage" do
      assert OpenAI.extract_usage(%{}) ==
               Usage.new(0, 0)
    end
  end
end
