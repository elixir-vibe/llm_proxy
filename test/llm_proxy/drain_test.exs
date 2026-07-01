defmodule LLMProxy.DrainTest do
  use ExUnit.Case, async: false

  setup do
    LLMProxy.Drain.cancel()
    :ok
  end

  test "tracks active request work and reports status" do
    assert %{draining: false, ready: true, active: %{total: 0}} = LLMProxy.Drain.status()

    assert {:ok, ref} = LLMProxy.Drain.enter(:request, %{route: :test})

    assert %{serving: true, active: %{total: 1, requests: 1, streams: 0, agents: 0}} =
             LLMProxy.Drain.status()

    assert :ok = LLMProxy.Drain.leave(ref)
    assert %{serving: false, active: %{total: 0}} = LLMProxy.Drain.status()
  end

  test "draining rejects new work and await_empty waits for active work" do
    assert {:ok, ref} = LLMProxy.Drain.enter(:stream, %{})

    assert %{draining: true, ready: false, active: %{total: 1, streams: 1}} =
             LLMProxy.Drain.start()

    assert {:error, :draining} = LLMProxy.Drain.enter(:request, %{})

    parent = self()

    task =
      Task.async(fn ->
        send(parent, :awaiting)
        LLMProxy.Drain.await_empty(1_000)
      end)

    assert_receive :awaiting
    Process.sleep(20)
    assert :ok = LLMProxy.Drain.leave(ref)
    assert :ok = Task.await(task)
  end

  test "track leaves work after function returns" do
    assert :done = LLMProxy.Drain.track(:agent, %{}, fn -> :done end)
    assert %{active: %{total: 0}} = LLMProxy.Drain.status()
  end
end
