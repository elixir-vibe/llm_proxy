defmodule LLMProxy.Providers.OpenRouter do
  @moduledoc false

  use LLMProxy.Providers.OpenAICompatibleProvider,
    name: "openrouter",
    provider_id: :openrouter,
    http_referer: "",
    title: "LLM Proxy"
end
