defmodule LLMProxy.Providers.OpenAI do
  @moduledoc false

  use LLMProxy.Providers.OpenAICompatibleProvider,
    name: "openai"
end
