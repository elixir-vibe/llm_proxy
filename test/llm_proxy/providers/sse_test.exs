defmodule LLMProxy.Providers.SSETest do
  use ExUnit.Case

  alias LLMProxy.Providers.SSE

  test "parse_events/1 parses multi-event chunks" do
    events =
      ["data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"]
      |> SSE.parse_events()
      |> Enum.to_list()

    assert Enum.map(events, & &1.data) == ["{\"a\":1}", "{\"b\":2}"]
  end
end
