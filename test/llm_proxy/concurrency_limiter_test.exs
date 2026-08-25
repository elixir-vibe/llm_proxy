defmodule LLMProxy.ConcurrencyLimiterTest do
  use ExUnit.Case, async: true

  alias LLMProxy.ConcurrencyLimiter
  alias LLMProxy.Limit

  test "normalizes concurrent limits without a usage window" do
    assert %Limit{metric: :concurrent_requests, window: nil, max: 3} =
             Limit.concurrent_requests(3)

    assert {:ok, [%Limit{metric: :concurrent_requests, window: nil, max: 2}]} =
             Limit.normalize([%{"metric" => "concurrent_requests", "max" => 2}])

    refute Limit.valid?([
             %{
               "metric" => "concurrent_requests",
               "window" => "minute",
               "max" => 2
             }
           ])

    refute Limit.valid?([%{"metric" => "concurrent_requests", "max" => 1.5}])

    assert Limit.concurrent_request_limit(%{
             budget_limits: [Limit.concurrent_requests(4), Limit.concurrent_requests(2)]
           }) == 2

    assert :ok =
             Limit.check(%{
               id: "no-storage-query",
               budget_limits: [Limit.concurrent_requests(1)]
             })
  end

  test "admits up to the per-key limit and exposes safe counters" do
    key = limited_key(1)
    before = ConcurrencyLimiter.status()

    assert {:ok, lease} = ConcurrencyLimiter.acquire(key)
    assert %{active: 1, limit: 1} = ConcurrencyLimiter.status(key)
    assert {:error, {:limit_exceeded, 1}} = ConcurrencyLimiter.acquire(key)

    assert :ok = ConcurrencyLimiter.release(lease)
    assert :ok = ConcurrencyLimiter.release(lease)
    assert %{active: 0, limit: 1} = ConcurrencyLimiter.status(key)

    after_status = ConcurrencyLimiter.status()
    assert after_status.admitted >= before.admitted + 1
    assert after_status.rejected >= before.rejected + 1
    assert after_status.released >= before.released + 1
  end

  test "releases a lease when its owner exits" do
    key = limited_key(1)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, _lease} = ConcurrencyLimiter.acquire(key)
        send(parent, :lease_acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :lease_acquired, 1_000
    assert %{active: 1} = ConcurrencyLimiter.status(key)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    assert_eventually(fn -> ConcurrencyLimiter.status(key).active == 0 end)
  end

  test "releases stream leases after completion, early halt, and exception" do
    key = limited_key(1)

    assert {:ok, completed_lease} = ConcurrencyLimiter.acquire(key)

    assert [1, 2] ==
             [1, 2]
             |> ConcurrencyLimiter.wrap_stream(completed_lease)
             |> Enum.to_list()

    assert %{active: 0} = ConcurrencyLimiter.status(key)

    assert {:ok, halted_lease} = ConcurrencyLimiter.acquire(key)

    assert [1] ==
             Stream.cycle([1, 2])
             |> ConcurrencyLimiter.wrap_stream(halted_lease)
             |> Enum.take(1)

    assert %{active: 0} = ConcurrencyLimiter.status(key)

    assert {:ok, raised_lease} = ConcurrencyLimiter.acquire(key)

    stream =
      Stream.map([:event], fn _event -> raise "stream failed" end)
      |> ConcurrencyLimiter.wrap_stream(raised_lease)

    assert_raise RuntimeError, "stream failed", fn -> Enum.to_list(stream) end
    assert %{active: 0} = ConcurrencyLimiter.status(key)
  end

  test "repeated stream cancellation returns the active count to zero" do
    key = limited_key(1)

    for iteration <- 1..25 do
      parent = self()
      assert {:ok, lease} = ConcurrencyLimiter.acquire(key)

      {pid, monitor} =
        spawn_monitor(fn ->
          stream =
            Stream.repeatedly(fn ->
              send(parent, {:stream_waiting, iteration, self()})

              receive do
                :continue -> :event
              end
            end)
            |> ConcurrencyLimiter.wrap_stream(lease)

          Enum.to_list(stream)
        end)

      assert_receive {:stream_waiting, ^iteration, ^pid}, 1_000
      assert %{active: 1} = ConcurrencyLimiter.status(key)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
      assert_eventually(fn -> ConcurrencyLimiter.status(key).active == 0 end)
    end
  end

  defp limited_key(limit) do
    %{
      id: "concurrency-test-#{System.unique_integer([:positive])}",
      budget_limits: [Limit.concurrent_requests(limit)]
    }
  end

  defp assert_eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)

      true ->
        flunk("condition did not become true")
    end
  end
end
