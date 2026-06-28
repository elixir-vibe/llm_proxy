defmodule LLMProxy.UsageTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Usage

  test "renders OpenAI usage from internal usage struct" do
    usage = Usage.new(10, 4, 3)

    assert Usage.to_openai(usage) == %{
             "prompt_tokens" => 10,
             "completion_tokens" => 4,
             "total_tokens" => 14,
             "prompt_tokens_details" => %{"cached_tokens" => 3}
           }
  end

  test "renders Responses usage from ReqLLM usage maps" do
    usage = %{input_tokens: 10, output_tokens: 4, cache_read_tokens: 3}

    assert Usage.to_responses(usage) == %{
             "input_tokens" => 10,
             "output_tokens" => 4,
             "total_tokens" => 14,
             "input_tokens_details" => %{"cached_tokens" => 3}
           }
  end
end
