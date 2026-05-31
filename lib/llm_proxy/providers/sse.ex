defmodule LLMProxy.Providers.SSE do
  @moduledoc false

  def parse_events(async_body) do
    Stream.transform(async_body, "", fn chunk, buffer ->
      {events, remaining} = ServerSentEvents.parse(buffer <> chunk)
      {events, remaining}
    end)
  end
end
