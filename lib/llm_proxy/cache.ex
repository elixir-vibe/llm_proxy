defmodule LLMProxy.Cache do
  @moduledoc """
  Behaviour for deterministic response cache adapters.

  Configure one adapter with:

      config :llm_proxy, cache: MyApp.LLMCache

  The adapter receives a deterministic cache key and context map. It stores and
  returns `%LLMProxy.Response{}` values; external adapters can serialize the
  response if needed.
  """

  alias LLMProxy.Response

  @type context :: %{
          optional(:actor) => LLMProxy.Actor.t(),
          optional(:api_key) => map(),
          optional(:route) => atom(),
          optional(:model) => String.t(),
          optional(:provider) => module(),
          optional(:trace_id) => String.t(),
          optional(:cache_key) => String.t(),
          optional(:metadata) => map()
        }

  @callback get(String.t(), context()) :: {:hit, Response.t()} | :miss | {:error, term()}
  @callback put(String.t(), Response.t(), context()) :: :ok | {:error, term()}

  @optional_callbacks put: 3
end
