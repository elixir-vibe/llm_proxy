defmodule LLMProxy.HTTP.Routes.NativeResults do
  @moduledoc false

  alias LLMProxy.Providers.Result

  def handle(
        conn,
        %Result{response: response, provider: provider, model: model},
        api_key,
        trace_id,
        handlers
      )
      when not is_nil(response) do
    handlers.non_stream.(conn, provider, response, api_key, model, trace_id)
  end

  def handle(
        conn,
        %Result{stream: stream, token: token, provider: provider, model: model},
        api_key,
        trace_id,
        handlers
      )
      when not is_nil(stream) do
    handlers.stream.(conn, provider, stream, api_key, model, token, trace_id)
  end
end
