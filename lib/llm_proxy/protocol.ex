defmodule LLMProxy.Protocol do
  @moduledoc """
  Protocol detection and conversion between LLM API formats.

  Each protocol module knows how to:
  - Render normalized requests to wire format
  - Convert responses back to its format
  - Handle streaming event conversion
  """

  @type protocol :: :openai | :anthropic

  @doc "Which protocol this module handles"
  @callback protocol() :: protocol()

  @doc "Convert a non-streaming response from source protocol to this protocol's format"
  @callback convert_response(response :: map(), from :: protocol(), model :: String.t()) :: map()

  @doc "Extract usage from a response in this protocol's native format"
  @callback extract_usage(response :: map()) :: LLMProxy.Providers.Behaviour.usage()

  def get_module(:openai), do: LLMProxy.Protocol.OpenAI
  def get_module(:anthropic), do: LLMProxy.Protocol.Anthropic
end
