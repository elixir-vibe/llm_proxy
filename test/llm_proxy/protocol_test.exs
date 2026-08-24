defmodule LLMProxy.ProtocolTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol
  alias LLMProxy.Protocol.{Anthropic, OpenAI, Request}

  test "get_module/1 resolves protocol modules" do
    assert Protocol.get_module(:openai) == OpenAI
    assert Protocol.get_module(:anthropic) == Anthropic
  end

  test "provider_request_body renders OpenAI provider requests" do
    request = %Request{
      protocol: :openai_chat,
      model: "proxy-model",
      body: %{"model" => "proxy-model"},
      messages: [ReqLLM.Context.user("hello")]
    }

    assert %{"model" => "upstream-model", "messages" => [%{"role" => "user"}]} =
             Protocol.provider_request_body(request, __MODULE__.OpenAIProvider, "upstream-model")
  end

  test "provider_request_body renders Anthropic provider requests" do
    request = %Request{
      protocol: :openai_chat,
      model: "proxy-model",
      body: %{"model" => "proxy-model"},
      messages: [ReqLLM.Context.user("hello")]
    }

    assert %{"model" => "claude", "messages" => [%{"role" => "user"}], "max_tokens" => _} =
             Protocol.provider_request_body(request, __MODULE__.AnthropicProvider, "claude")
  end

  defmodule OpenAIProvider do
  end

  defmodule AnthropicProvider do
    def native_protocol, do: :anthropic
  end
end
