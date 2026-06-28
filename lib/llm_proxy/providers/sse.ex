defmodule LLMProxy.Providers.SSE do
  @moduledoc """
  Server-sent-events decoder wrapper used by streaming provider clients.
  """

  def parse_events(async_body) do
    ServerSentEvents.decode_stream(async_body)
  end
end
