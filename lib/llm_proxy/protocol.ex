defmodule LLMProxy.Protocol do
  @moduledoc """
  Protocol detection and conversion between LLM API formats.

  Each protocol module knows how to:
  - Render normalized requests to wire format
  - Convert responses back to its format
  - Handle streaming event conversion
  """

  alias LLMProxy.Protocol.{Anthropic, OpenAI, Request}

  @type protocol :: :openai | :anthropic

  @doc "Which protocol this module handles"
  @callback protocol() :: protocol()

  @doc "Convert a non-streaming response from source protocol to this protocol's format"
  @callback convert_response(response :: map(), from :: protocol(), model :: String.t()) :: map()

  @doc "Extract usage from a response in this protocol's native format"
  @callback extract_usage(response :: map()) :: LLMProxy.Providers.Behaviour.usage()

  @spec provider_request_body(Request.t(), module(), String.t()) :: map()
  def provider_request_body(%Request{} = request, provider, model) when is_binary(model) do
    request = %{request | model: model, body: Map.put(request.body, "model", model)}

    case provider_protocol(provider) do
      :anthropic ->
        Anthropic.request_body(
          request,
          max_tokens: LLMProxy.Config.provider_conversion_default("anthropic", :max_tokens)
        )

      :openai ->
        OpenAI.request_body(request)
    end
  end

  def get_module(:openai), do: OpenAI
  def get_module(:anthropic), do: Anthropic

  @doc false
  @spec stringify_keys(term()) :: term()
  def stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)

  def stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {string_key(key), stringify_keys(nested)} end)
  end

  def stringify_keys(value), do: value

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: key

  defp provider_protocol(provider) do
    if function_exported?(provider, :native_protocol, 0),
      do: provider.native_protocol(),
      else: :openai
  end
end
