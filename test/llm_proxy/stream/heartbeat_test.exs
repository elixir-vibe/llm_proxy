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

  test "projects a failure raised before the first upstream event" do
    stream = Stream.map([:event], fn _event -> raise "upstream rejected the request" end)

    assert [%Heartbeat.Failure{reason: %RuntimeError{message: message}}] =
             stream |> Heartbeat.wrap(100) |> Enum.to_list()

    assert message == "upstream rejected the request"
  end

  test "preserves events emitted before a later upstream failure" do
    stream =
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {[:first], :failure}
          :failure -> raise "upstream disconnected"
        end,
        fn _state -> :ok end
      )

    assert [:first, %Heartbeat.Failure{reason: %RuntimeError{message: message}}] =
             stream |> Heartbeat.wrap(100) |> Enum.to_list()

    assert message == "upstream disconnected"
  end
end
