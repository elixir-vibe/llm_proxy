defmodule LLMProxy.ModelDBTest do
  use ExUnit.Case, async: true

  test "maps proxy provider modules and atoms to LLMDB provider ids" do
    assert LLMProxy.ModelDB.provider_id(LLMProxy.Providers.OpenAI) == :openai
    assert LLMProxy.ModelDB.provider_id(:anthropic) == :anthropic
    assert LLMProxy.ModelDB.provider_id(:openrouter) == :openrouter
  end

  test "loads provider model ids from LLMDB" do
    assert "gpt-4o" in LLMProxy.ModelDB.provider_model_ids(:openai)

    assert Enum.any?(
             LLMProxy.ModelDB.provider_model_ids(:anthropic),
             &String.starts_with?(&1, "claude-")
           )
  end

  test "gets pricing from LLMDB" do
    pricing = LLMProxy.ModelDB.pricing("gpt-4o", :openai)

    assert %LLMProxy.Pricing.Rates{} = pricing
    assert is_number(pricing.input)
    assert is_number(pricing.output)
  end
end
