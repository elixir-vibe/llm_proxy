defmodule LLMProxy.Providers.Behaviour do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Providers receive native request bodies and return `LLMProxy.Providers.Result` structs.
  Wire JSON stays at protocol/provider boundaries.
  """

  @type usage :: LLMProxy.Usage.t()

  @type call_result ::
          {:ok, LLMProxy.Providers.Result.t()} | {:error, LLMProxy.Providers.Result.t()}

  @type stream :: Enumerable.t()
  @type stream_result ::
          {:ok, LLMProxy.Providers.Result.t()} | {:error, LLMProxy.Providers.Result.t()}

  @doc ~s(Provider name, e.g. "anthropic", "openrouter")
  @callback name() :: String.t()

  @doc "The native API protocol this provider speaks (:openai or :anthropic)"
  @callback native_protocol() :: :openai | :anthropic

  @doc "List of model IDs this provider handles"
  @callback models() :: [String.t()]

  @doc "Non-streaming call. Body is in the provider's native protocol format."
  @callback call(body :: map(), user_id :: String.t()) :: call_result()

  @doc "Streaming call. Body is in the provider's native protocol format."
  @callback stream(body :: map(), user_id :: String.t()) :: stream_result()

  @doc "Non-streaming native passthrough. Routes pass the validated native wire body explicitly."
  @callback call_native(body :: map(), user_id :: String.t()) :: call_result()

  @doc "Streaming native passthrough. Routes pass the validated native wire body explicitly."
  @callback stream_native(body :: map(), user_id :: String.t()) :: stream_result()

  @doc "Project an exception raised while lazily consuming a provider stream"
  @callback stream_error(reason :: term(), token :: map() | nil) ::
              LLMProxy.Providers.Result.t()

  @doc "Extract usage from a non-streaming response body"
  @callback extract_usage(response :: map()) :: usage()

  @doc "Convert native response to OpenAI chat completion format"
  @callback to_openai_response(response :: map(), model :: String.t()) :: map()

  @optional_callbacks [call_native: 2, stream_native: 2, stream_error: 2]
end
