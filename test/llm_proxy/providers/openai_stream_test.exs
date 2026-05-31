defmodule LLMProxy.Providers.OpenAIStreamTest do
  use ExUnit.Case

  alias LLMProxy.Providers.OpenAIStream
  alias LLMProxy.Usage

  test "from_map/1 extracts usage" do
    event =
      OpenAIStream.from_map(%{
        "usage" => %{
          "prompt_tokens" => 3,
          "completion_tokens" => 2,
          "prompt_tokens_details" => %{"cached_tokens" => 1}
        }
      })

    assert event.usage == Usage.new(3, 2, 1, 0)
  end
end
