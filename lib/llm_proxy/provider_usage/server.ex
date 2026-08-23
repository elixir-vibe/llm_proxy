defmodule LLMProxy.ProviderUsage.Server do
  @moduledoc """
  Supervised cache and bounded refresh scheduler for provider usage.

  One task refreshes accounts sequentially. A second manual or automatic
  request cannot start another task while that refresh is active.
  """

  use GenServer

  alias LLMProxy.ProviderUsage.{Loader, Snapshot}

  defmodule State do
    @moduledoc false
    defstruct [
      :task,
      :scope,
      :timer,
      :task_supervisor,
      :refresh_fun,
      snapshots: %{},
      auto_refresh: true,
      refresh_interval_ms: 300_000,
      stale_after_ms: 600_000
    ]
  end

  @type scope :: :all | {:account, integer()}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshots(GenServer.server()) :: [Snapshot.t()]
  def snapshots(server \\ __MODULE__) do
    snapshots_at(server, DateTime.utc_now())
  end

  @doc false
  @spec snapshots_at(GenServer.server(), DateTime.t()) :: [Snapshot.t()]
  def snapshots_at(server, %DateTime{} = at) do
    GenServer.call(server, {:snapshots, at})
  end

  @spec refresh_all(GenServer.server()) :: {:ok, :started | :already_refreshing}
  def refresh_all(server \\ __MODULE__), do: GenServer.call(server, {:refresh, :all})

  @spec refresh_account(integer(), GenServer.server()) :: {:ok, :started | :already_refreshing}
  def refresh_account(id, server \\ __MODULE__) when is_integer(id) do
    GenServer.call(server, {:refresh, {:account, id}})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    auto_refresh =
      Keyword.get(opts, :auto_refresh, LLMProxy.Config.provider_usage_auto_refresh?())

    state = %State{
      auto_refresh: auto_refresh,
      refresh_interval_ms:
        Keyword.get(
          opts,
          :refresh_interval_ms,
          LLMProxy.Config.provider_usage_refresh_interval_ms()
        ),
      stale_after_ms:
        Keyword.get(opts, :stale_after_ms, LLMProxy.Config.provider_usage_stale_after_ms()),
      task_supervisor: Keyword.get(opts, :task_supervisor, LLMProxy.ProviderUsage.TaskSupervisor),
      refresh_fun: Keyword.get(opts, :refresh_fun, &Loader.refresh/1)
    }

    {:ok, schedule_initial(state)}
  end

  @impl true
  def handle_call({:snapshots, at}, _from, state) do
    snapshots =
      state.snapshots
      |> Enum.map(fn {_token_id, snapshot} ->
        stale_snapshot(snapshot, at, state.stale_after_ms)
      end)
      |> Enum.sort_by(& &1.token_id)

    {:reply, snapshots, state}
  end

  def handle_call({:refresh, scope}, _from, %State{task: nil} = state) do
    {:reply, {:ok, :started}, start_refresh(state, scope)}
  end

  def handle_call({:refresh, _scope}, _from, state) do
    {:reply, {:ok, :already_refreshing}, state}
  end

  @impl true
  def handle_info(:auto_refresh, %State{task: nil} = state) do
    {:noreply, start_refresh(%{state | timer: nil}, :all)}
  end

  def handle_info(:auto_refresh, state), do: {:noreply, %{state | timer: nil}}

  def handle_info({ref, snapshots}, %State{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> apply_refresh(snapshots)
      |> finish_refresh()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{task: %Task{ref: ref}} = state) do
    state =
      state
      |> fail_refresh()
      |> finish_refresh()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer)
    cancel_task(state)
    :ok
  end

  defp start_refresh(state, scope) do
    cancel_timer(state.timer)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        state.refresh_fun.(scope)
      end)

    Process.link(task.pid)

    %{
      state
      | task: task,
        scope: scope,
        timer: nil,
        snapshots: mark_refreshing(state.snapshots, scope)
    }
  end

  defp apply_refresh(state, snapshots) when is_list(snapshots) do
    snapshots = Enum.filter(snapshots, &match?(%Snapshot{}, &1))

    refreshed =
      case state.scope do
        :all ->
          Map.new(snapshots, fn snapshot ->
            {snapshot.token_id, merge_snapshot(state.snapshots[snapshot.token_id], snapshot)}
          end)

        {:account, id} ->
          state.snapshots
          |> Map.delete(id)
          |> Map.merge(
            Map.new(snapshots, fn snapshot ->
              {snapshot.token_id, merge_snapshot(state.snapshots[snapshot.token_id], snapshot)}
            end)
          )
      end

    %{state | snapshots: refreshed}
  end

  defp apply_refresh(state, _invalid_result), do: fail_refresh(state)

  defp merge_snapshot(
         %Snapshot{refreshed_at: %DateTime{}} = previous,
         %Snapshot{state: :error} = failed
       ) do
    %{
      failed
      | availability: previous.availability,
        state: :stale,
        plan: previous.plan,
        windows: previous.windows,
        refreshed_at: previous.refreshed_at
    }
  end

  defp merge_snapshot(_previous, snapshot), do: snapshot

  defp fail_refresh(state) do
    snapshots =
      Map.new(state.snapshots, fn {id, snapshot} ->
        if selected?(id, state.scope) do
          failed = %{
            snapshot
            | state: if(snapshot.refreshed_at, do: :stale, else: :error),
              error: "Provider usage refresh failed",
              attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }

          {id, failed}
        else
          {id, snapshot}
        end
      end)

    %{state | snapshots: snapshots}
  end

  defp finish_refresh(state) do
    state
    |> Map.put(:task, nil)
    |> Map.put(:scope, nil)
    |> schedule_next()
  end

  defp mark_refreshing(snapshots, scope) do
    Map.new(snapshots, fn {id, snapshot} ->
      if selected?(id, scope) do
        {id, %{snapshot | state: :refreshing, error: nil}}
      else
        {id, snapshot}
      end
    end)
  end

  defp selected?(_id, :all), do: true
  defp selected?(id, {:account, id}), do: true
  defp selected?(_id, _scope), do: false

  defp stale_snapshot(
         %Snapshot{state: :fresh, refreshed_at: refreshed_at} = snapshot,
         at,
         max_age
       )
       when not is_nil(refreshed_at) do
    if DateTime.diff(at, refreshed_at, :millisecond) > max_age do
      %{snapshot | state: :stale, error: snapshot.error || "Provider usage data is stale"}
    else
      snapshot
    end
  end

  defp stale_snapshot(snapshot, _at, _max_age), do: snapshot

  defp schedule_initial(%State{auto_refresh: true} = state) do
    %{state | timer: Process.send_after(self(), :auto_refresh, 1_000)}
  end

  defp schedule_initial(state), do: state

  defp schedule_next(%State{auto_refresh: true} = state) do
    %{state | timer: Process.send_after(self(), :auto_refresh, state.refresh_interval_ms)}
  end

  defp schedule_next(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp cancel_task(%State{task: nil}), do: :ok

  defp cancel_task(%State{task: task, task_supervisor: supervisor}) do
    _result = Task.Supervisor.terminate_child(supervisor, task.pid)
    :ok
  end
end
