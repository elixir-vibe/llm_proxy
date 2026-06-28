defmodule LLMProxy.Providers.OpenAI do
  @moduledoc """
  Built-in OpenAI provider backed by the shared OpenAI-compatible provider implementation.
  """

  use LLMProxy.Providers.OpenAICompatibleProvider,
    name: "openai",
    provider_id: :openai
end
