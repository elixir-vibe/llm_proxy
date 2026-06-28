defmodule LLMProxy.Protocol.RequestTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol.Request

  test "parses OpenAI chat requests into ReqLLM messages and normalized options" do
    assert {:ok, request} =
             Request.parse(:openai_chat, %{
               "model" => "gpt-4o",
               "messages" => [%{"role" => "user", "content" => "hello"}],
               "stream" => true,
               "max_tokens" => 20,
               "temperature" => 0.2,
               "top_p" => 0.9,
               "metadata" => %{"tags" => ["a"], "session_id" => "s1"}
             })

    assert request.model == "gpt-4o"
    assert request.stream == true
    assert request.max_tokens == 20
    assert request.temperature == 0.2
    assert request.top_p == 0.9
    assert request.tags == ["a"]
    assert request.metadata == %{"session_id" => "s1"}

    assert [
             %ReqLLM.Message{
               role: :user,
               content: [%ReqLLM.Message.ContentPart{type: :text, text: "hello"}]
             }
           ] =
             request.messages
  end

  test "extracts OpenAI chat user text from normalized messages" do
    assert {:ok, request} =
             Request.parse(:openai_chat, %{
               "messages" => [
                 %{"role" => "user", "content" => "first"},
                 %{"role" => "assistant", "content" => "ok"},
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "text", "text" => "hello"},
                     %{"type" => "text", "text" => "world"}
                   ]
                 }
               ]
             })

    assert Request.user_text(request) == "hello\nworld"
  end

  test "ignores Anthropic tool-result-only user messages" do
    assert {:ok, request} =
             Request.parse(:anthropic_messages, %{
               "messages" => [
                 %{"role" => "user", "content" => [%{"type" => "text", "text" => "ask"}]},
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "tool_result", "tool_use_id" => "call_1", "content" => "done"}
                   ]
                 }
               ]
             })

    assert Request.user_text(request) == "ask"
  end

  test "parses OpenAI image_url content" do
    assert {:ok, request} =
             Request.parse(:openai_chat, %{
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "text", "text" => "look"},
                     %{
                       "type" => "image_url",
                       "image_url" => %{"url" => "https://example.test/a.png"}
                     }
                   ]
                 }
               ]
             })

    assert [message] = request.messages

    assert [
             %ReqLLM.Message.ContentPart{type: :text, text: "look"},
             %ReqLLM.Message.ContentPart{type: :image_url, url: "https://example.test/a.png"}
           ] = message.content
  end

  test "parses Anthropic image blocks" do
    assert {:ok, request} =
             Request.parse(:anthropic_messages, %{
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => [
                     %{
                       "type" => "image",
                       "source" => %{
                         "type" => "base64",
                         "media_type" => "image/png",
                         "data" => "abc"
                       }
                     }
                   ]
                 }
               ]
             })

    assert [
             %ReqLLM.Message{
               content: [
                 %ReqLLM.Message.ContentPart{type: :image, media_type: "image/png", data: "abc"}
               ]
             }
           ] =
             request.messages
  end

  test "parses Anthropic thinking blocks" do
    assert {:ok, request} =
             Request.parse(:anthropic_messages, %{
               "messages" => [
                 %{
                   "role" => "assistant",
                   "content" => [%{"type" => "thinking", "thinking" => "considering"}]
                 }
               ]
             })

    assert [
             %ReqLLM.Message{
               content: [%ReqLLM.Message.ContentPart{type: :thinking, text: "considering"}]
             }
           ] =
             request.messages
  end

  test "parses Responses API input files" do
    assert {:ok, request} =
             Request.parse(:openai_responses, %{
               "input" => [
                 %{
                   "role" => "user",
                   "content" => [%{"type" => "input_file", "file_id" => "file_123"}]
                 }
               ]
             })

    assert [
             %ReqLLM.Message{
               content: [
                 %ReqLLM.Message.ContentPart{type: :file, file_id: "file_123"}
               ]
             }
           ] =
             request.messages
  end

  test "parses Responses API function call output" do
    assert {:ok, request} =
             Request.parse(:openai_responses, %{
               "input" => [
                 %{"type" => "function_call_output", "call_id" => "call_1", "output" => "42"}
               ]
             })

    assert [%ReqLLM.Message{role: :tool, tool_call_id: "call_1"}] = request.messages
  end

  test "parses Responses API assistant function calls" do
    assert {:ok, request} =
             Request.parse(:openai_responses, %{
               "input" => [
                 %{
                   "type" => "function_call",
                   "id" => "item_1",
                   "call_id" => "call_1",
                   "name" => "lookup",
                   "arguments" => %{"id" => 1}
                 }
               ]
             })

    assert [%ReqLLM.Message{role: :assistant, tool_calls: [tool_call]}] = request.messages
    assert tool_call.id == "call_1"
    assert ReqLLM.ToolCall.name(tool_call) == "lookup"
    assert ReqLLM.ToolCall.args_json(tool_call) == "{\"id\":1}"
  end

  test "extracts Responses API input text" do
    assert {:ok, request} =
             Request.parse(:openai_responses, %{
               "input" => [
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "input_text", "text" => "one"},
                     %{"type" => "text", "text" => "two"}
                   ]
                 }
               ]
             })

    assert Request.user_text(request) == "one\ntwo"
  end

  test "rejects invalid message shapes" do
    assert {:error, %Request.Error{code: "invalid_message", message: message}} =
             Request.parse(:openai_chat, %{
               "messages" => [%{"role" => "wat", "content" => "hello"}]
             })

    assert message == "Unsupported or malformed message"
  end
end
