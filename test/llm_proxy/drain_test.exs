defmodule LLMProxy.DrainTest do
  use ExUnit.Case, async: false

  setup do
    LLMProxy.Drain.cancel()
    on_exit(fn -> LLMProxy.Drain.cancel() end)
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

  test "await_empty times out without poisoning later waits" do
    assert {:ok, ref} = LLMProxy.Drain.enter(:agent, %{})
    assert {:error, :timeout} = LLMProxy.Drain.await_empty(10)

    parent = self()

    task =
      Task.async(fn ->
        send(parent, :awaiting_after_timeout)
        LLMProxy.Drain.await_empty(1_000)
      end)

    assert_receive :awaiting_after_timeout
    assert :ok = LLMProxy.Drain.leave(ref)
    assert :ok = Task.await(task)
  end

  test "track leaves work after function returns" do
    assert :done = LLMProxy.Drain.track(:agent, %{}, fn -> :done end)
    assert %{active: %{total: 0}} = LLMProxy.Drain.status()
  end

  test "owner exit releases work and wakes drain waiters" do
    parent = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        assert {:ok, _ref} = LLMProxy.Drain.enter(:stream, %{route: :disconnect})
        send(parent, :owner_entered)
        Process.sleep(:infinity)
      end)

    assert_receive :owner_entered, 1_000
    assert %{active: %{total: 1, streams: 1}} = LLMProxy.Drain.start()

    waiter = Task.async(fn -> LLMProxy.Drain.await_empty(1_000) end)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000
    assert :ok = Task.await(waiter)
    assert %{active: %{total: 0, streams: 0}} = LLMProxy.Drain.status()
  end
end
