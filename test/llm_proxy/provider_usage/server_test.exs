defmodule LLMProxy.ProviderUsage.ServerTest do
  use ExUnit.Case, async: false

  alias LLMProxy.ProviderUsage.{Server, Snapshot, Window}

  test "serializes refreshes, preserves stale data on errors, and detects age" do
    parent = self()
    task_supervisor = unique_name(:tasks)
    server = unique_name(:server)

    start_supervised!({Task.Supervisor, name: task_supervisor, max_children: 1})

    refresh_fun = fn scope ->
      send(parent, {:refresh_started, self(), scope})

      receive do
        {:finish_refresh, result} -> result
      end
    end

    start_supervised!(
      {Server,
       name: server,
       task_supervisor: task_supervisor,
       refresh_fun: refresh_fun,
       auto_refresh: false,
       refresh_interval_ms: 60_000,
       stale_after_ms: 60_000}
    )

    refreshed_at = ~U[2026-08-23 12:00:00Z]
    fresh = snapshot(refreshed_at, :fresh, nil, [window()])

    assert {:ok, :started} = Server.refresh_all(server)
    assert_receive {:refresh_started, first_task, :all}
    assert {:ok, :already_refreshing} = Server.refresh_account(1, server)
    send(first_task, {:finish_refresh, [fresh]})

    assert eventually(fn -> Server.snapshots_at(server, refreshed_at) == [fresh] end)

    assert [%{state: :stale, error: "Provider usage data is stale"}] =
             Server.snapshots_at(server, DateTime.add(refreshed_at, 61, :second))

    failed = snapshot(nil, :error, "Provider usage API timed out", [])

    assert {:ok, :started} = Server.refresh_account(1, server)
    assert_receive {:refresh_started, second_task, {:account, 1}}
    send(second_task, {:finish_refresh, [failed]})

    assert eventually(fn ->
             case Server.snapshots_at(server, refreshed_at) do
               [%{state: :stale, error: "Provider usage API timed out", windows: [_window]}] ->
                 true

               _other ->
                 false
             end
           end)
  end

  test "rejects malformed, duplicate, and out-of-scope refresh results atomically" do
    parent = self()
    task_supervisor = unique_name(:strict_tasks)
    server = unique_name(:strict_server)

    start_supervised!({Task.Supervisor, name: task_supervisor, max_children: 1})

    refresh_fun = fn scope ->
      send(parent, {:refresh_started, self(), scope})

      receive do
        {:finish_refresh, result} -> result
      end
    end

    start_supervised!(
      {Server,
       name: server,
       task_supervisor: task_supervisor,
       refresh_fun: refresh_fun,
       auto_refresh: false,
       stale_after_ms: 60_000}
    )

    at = ~U[2026-08-23 12:00:00Z]
    fresh = snapshot(at, :fresh, nil, [window()])

    assert {:ok, :started} = Server.refresh_all(server)
    assert_receive {:refresh_started, seed_task, :all}
    send(seed_task, {:finish_refresh, [fresh]})
    assert eventually(fn -> Server.snapshots_at(server, at) == [fresh] end)

    assert {:ok, :started} = Server.refresh_account(1, server)
    assert_receive {:refresh_started, wrong_scope_task, {:account, 1}}
    send(wrong_scope_task, {:finish_refresh, [snapshot(at, :fresh, nil, [window()], 2)]})

    assert eventually(fn ->
             match?(
               [%{token_id: 1, state: :stale, error: "Provider usage refresh failed"}],
               Server.snapshots_at(server, at)
             )
           end)

    assert {:ok, :started} = Server.refresh_all(server)
    assert_receive {:refresh_started, duplicate_task, :all}
    send(duplicate_task, {:finish_refresh, [fresh, fresh]})

    assert eventually(fn ->
             match?([%{token_id: 1, state: :stale}], Server.snapshots_at(server, at))
           end)
  end

  test "stops an active refresh task when the cache stops" do
    parent = self()
    task_supervisor = unique_name(:cleanup_tasks)
    server = unique_name(:cleanup_server)

    start_supervised!({Task.Supervisor, name: task_supervisor, max_children: 1})

    refresh_fun = fn scope ->
      send(parent, {:refresh_started, self(), scope})

      receive do
        :never -> []
      end
    end

    start_supervised!(
      {Server,
       name: server,
       task_supervisor: task_supervisor,
       refresh_fun: refresh_fun,
       auto_refresh: true,
       refresh_interval_ms: 60_000,
       stale_after_ms: 120_000}
    )

    assert_receive {:refresh_started, task, :all}, 1_500
    monitor = Process.monitor(task)

    assert :ok = stop_supervised(Server)
    assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 1_000
  end

  defp snapshot(refreshed_at, state, error, windows, token_id \\ 1) do
    %Snapshot{
      token_id: token_id,
      provider_label: "OpenAI Codex",
      account_label: "Account #1",
      availability: if(state == :error, do: :unknown, else: :available),
      state: state,
      windows: windows,
      refreshed_at: refreshed_at,
      attempted_at: ~U[2026-08-23 12:00:00Z],
      error: error
    }
  end

  defp window do
    %Window{
      label: "5 hour",
      used_percent: 40,
      remaining_percent: 60,
      resets_at: ~U[2026-08-23 14:00:00Z],
      duration_seconds: 18_000
    }
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end
end
