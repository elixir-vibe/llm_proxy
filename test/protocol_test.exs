defmodule LLMProxy.ProtocolTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol
  alias LLMProxy.Protocol.{Anthropic, OpenAI}

  test "get_module/1 resolves protocol modules" do
    assert Protocol.get_module(:openai) == OpenAI
    assert Protocol.get_module(:anthropic) == Anthropic
  end
end
