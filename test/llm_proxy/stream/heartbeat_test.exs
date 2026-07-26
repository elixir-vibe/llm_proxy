defmodule LLMProxy.Stream.HeartbeatTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LLMProxy.Stream.Heartbeat
  alias LLMProxy.Telemetry

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

  test "logs and emits telemetry for lazy stream failures" do
    handler_id = "heartbeat-stream-failure-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:llm_proxy, :routing, :stream_attempt, :exception],
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stream = Stream.map([:event], fn _event -> raise "WebSocket closed 1000" end)

    log =
      capture_log(fn ->
        assert [%Heartbeat.Failure{}] =
                 Heartbeat.wrap(stream,
                   telemetry:
                     Telemetry.stream_context(
                       "openai-codex",
                       "gpt-5.6-sol",
                       "trace-stream-failure"
                     )
                 )
                 |> Enum.to_list()
      end)

    assert_receive {[:llm_proxy, :routing, :stream_attempt, :exception],
                    %{status: 502} = measurements, %{trace_id: "trace-stream-failure"} = metadata}

    assert is_integer(measurements.system_time)
    assert metadata.provider == "openai-codex"
    assert metadata.model == "gpt-5.6-sol"
    assert metadata.trace_id == "trace-stream-failure"
    assert metadata.error_message == "WebSocket closed 1000"
    assert metadata.lazy == true

    assert log =~ "provider=openai-codex"
    assert log =~ "trace_id=trace-stream-failure"
    assert log =~ ~s(reason="WebSocket closed 1000")
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
