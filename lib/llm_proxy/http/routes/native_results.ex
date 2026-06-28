defmodule LLMProxy.HTTP.Routes.NativeResults do
  @moduledoc false

  alias LLMProxy.Providers.Result

  def handle(
        conn,
        %Result{kind: :response, response: response, provider: provider, model: model},
        api_key,
        trace_id,
        handlers
      ) do
    handlers.non_stream.(conn, provider, response, api_key, model, trace_id)
  end

  def handle(
        conn,
        %Result{kind: :stream, stream: stream, token: token, provider: provider, model: model},
        api_key,
        trace_id,
        handlers
      ) do
    handlers.stream.(conn, provider, stream, api_key, model, token, trace_id)
  end
end
