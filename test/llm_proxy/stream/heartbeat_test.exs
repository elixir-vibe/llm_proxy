defmodule LLMProxy.Stream.HeartbeatTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Stream.Heartbeat

  test "emits bounded heartbeats while the upstream stream is silent" do
    stream =
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {[:first], :silent}

          :silent ->
            Process.sleep(45)
            {[:second], :done}

          :done ->
            {:halt, :done}
        end,
        fn _state -> :ok end
      )

    events = stream |> Heartbeat.wrap(10) |> Enum.to_list()

    assert hd(events) == :first
    assert List.last(events) == :second
    assert Enum.count(events, &match?(%Heartbeat{}, &1)) >= 3
  end

  test "does not add a heartbeat when upstream events remain available" do
    assert Heartbeat.wrap([:first, :second], 100) |> Enum.to_list() == [:first, :second]
  end
end
