defmodule LLMProxy.Providers.OpenRouter do
  @moduledoc """
  Built-in OpenRouter provider backed by the shared OpenAI-compatible provider implementation.
  """

  use LLMProxy.Providers.OpenAICompatible.Definition,
    name: "openrouter",
    provider_id: :openrouter,
    http_referer: "",
    title: "LLM Proxy"
end
