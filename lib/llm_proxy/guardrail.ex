defmodule LLMProxy.Guardrail do
  @moduledoc """
  Behaviour for host-defined request/response policy hooks.

  Guardrails are configured with:

      config :llm_proxy, guardrails: [MyApp.LLMPolicy]

  Callbacks run in order. They should be deterministic and side-effect-light.
  """

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Response
  alias LLMProxy.Stream.Event

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

  @callback before_request(Request.t(), context()) :: {:ok, Request.t()} | {:error, term()}
  @callback after_response(Response.t(), context()) :: {:ok, Response.t()} | {:error, term()}
  @callback on_stream_event(Event.t(), context()) :: {:ok, Event.t() | nil} | {:error, term()}

  @optional_callbacks before_request: 2, after_response: 2, on_stream_event: 2
end
