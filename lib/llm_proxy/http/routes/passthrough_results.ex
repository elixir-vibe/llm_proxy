defmodule LLMProxy.HTTP.Routes.PassthroughResults do
  @moduledoc """
  Dispatches successful provider-passthrough results to route-specific renderers.

  Passthrough routes keep the provider API shape at the HTTP boundary while
  sharing the common `LLMProxy.Providers.Result` response/stream dispatch here.
  """

  alias LLMProxy.Providers.Result

  defmodule Handlers do
    @moduledoc """
    Route callbacks used to render passthrough non-streaming and streaming results.
    """

    @enforce_keys [:non_stream, :stream]
    defstruct [:non_stream, :stream]

    @type non_stream :: (Plug.Conn.t(), module(), map(), map(), String.t(), String.t() ->
                           Plug.Conn.t())

    @type stream :: (Plug.Conn.t(),
                     module(),
                     Enumerable.t(),
                     map(),
                     String.t(),
                     map()
                     | nil,
                     String.t() ->
                       Plug.Conn.t())

    @type t :: %__MODULE__{non_stream: non_stream(), stream: stream()}
  end

  @spec handlers(Handlers.non_stream(), Handlers.stream()) :: Handlers.t()
  def handlers(non_stream, stream) when is_function(non_stream, 6) and is_function(stream, 7) do
    %Handlers{non_stream: non_stream, stream: stream}
  end

  @spec handle(Plug.Conn.t(), Result.t(), map(), String.t(), Handlers.t()) :: Plug.Conn.t()
  def handle(
        conn,
        %Result{kind: :response, response: response, provider: provider, model: model},
        api_key,
        trace_id,
        %Handlers{} = handlers
      ) do
    handlers.non_stream.(conn, provider, response, api_key, model, trace_id)
  end

  def handle(
        conn,
        %Result{kind: :stream, stream: stream, token: token, provider: provider, model: model},
        api_key,
        trace_id,
        %Handlers{} = handlers
      ) do
    handlers.stream.(conn, provider, stream, api_key, model, token, trace_id)
  end
end
