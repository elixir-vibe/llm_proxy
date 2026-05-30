defmodule LLMProxy.Protocol.OpenAIRequestTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol.{OpenAI, Request}

  test "renders Responses input files to OpenAI wire format" do
    {:ok, request} =
      Request.parse(:openai_responses, %{
        "model" => "gpt-4o",
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_file", "file_id" => "file_123"}]
          }
        ]
      })

    assert %{"messages" => [%{"content" => [%{"file" => %{"file_id" => "file_123"}}]}]} =
             OpenAI.request_body(request)
  end

  test "renders normalized image content to OpenAI wire format" do
    {:ok, request} =
      Request.parse(:anthropic_messages, %{
        "model" => "gpt-4o",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "look"},
              %{
                "type" => "image",
                "source" => %{"type" => "url", "url" => "https://example.test/a.png"}
              }
            ]
          }
        ]
      })

    assert %{"messages" => [%{"content" => content}]} = OpenAI.request_body(request)

    assert content == [
             %{"type" => "text", "text" => "look"},
             %{"type" => "image_url", "image_url" => %{"url" => "https://example.test/a.png"}}
           ]
  end
end
