defmodule LLMProxy.Providers.KimiCode do
  @moduledoc """
  Direct Kimi Code provider backed by Kimi's OpenAI-compatible coding API.

  This provider is intentionally separate from Moonshot's pay-as-you-go API and
  OpenRouter. Kimi Code membership keys authenticate against
  `https://api.kimi.com/coding/v1` and Kimi K3 uses the upstream model ID `k3`.
  """

  use LLMProxy.Providers.OpenAICompatible.Definition,
    name: "kimi-code",
    models: []
end
