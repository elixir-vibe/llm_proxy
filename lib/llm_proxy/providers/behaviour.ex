defmodule LLMProxy.Providers.Behaviour do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Providers receive raw request bodies (maps) and return raw responses.
  The proxy passes JSON through — no struct conversion.
  """

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer()
        }

  @type call_result ::
          {:ok, %{response: map(), token: map() | nil}}
          | {:error, %{error: String.t(), status: integer(), token: map() | nil}}

  @type stream_result ::
          {:ok, %{stream: Enumerable.t(), token: map() | nil}}
          | {:error, %{error: String.t(), status: integer(), token: map() | nil}}

  @doc ~s(Provider name, e.g. "anthropic", "openrouter")
  @callback name() :: String.t()

  @doc "List of model IDs this provider handles"
  @callback models() :: [String.t()]

  @doc "Non-streaming call with OpenAI-format body"
  @callback call(body :: map(), user_id :: String.t()) :: call_result()

  @doc "Streaming call with OpenAI-format body"
  @callback stream(body :: map(), user_id :: String.t()) :: stream_result()

  @doc "Non-streaming native passthrough (provider's own API format)"
  @callback call_native(body :: map(), user_id :: String.t()) :: call_result()

  @doc "Streaming native passthrough"
  @callback stream_native(body :: map(), user_id :: String.t()) :: stream_result()

  @doc "Extract usage from a non-streaming response body"
  @callback extract_usage(response :: map()) :: usage()

  @doc "Convert native response to OpenAI chat completion format"
  @callback to_openai_response(response :: map(), model :: String.t()) :: map()

  @optional_callbacks [call_native: 2, stream_native: 2]
end
