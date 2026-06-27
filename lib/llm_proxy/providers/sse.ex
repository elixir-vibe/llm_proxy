defmodule LLMProxy.Providers.SSE do
  @moduledoc false

  def parse_events(async_body) do
    ServerSentEvents.decode_stream(async_body)
  end
end
