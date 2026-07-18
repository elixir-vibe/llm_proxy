defmodule LLMProxy.Stream.Heartbeat do
  @moduledoc """
  Adds periodic heartbeat markers while an upstream enumerable is silent.

  The producer is pulled at most one event ahead so slow HTTP clients cannot cause
  unbounded buffering. Consumers render heartbeat markers as SSE comments.
  """

  @default_interval_ms 15_000

  defstruct []

  @type t :: %__MODULE__{}

  @spec wrap(Enumerable.t(), pos_integer()) :: Enumerable.t()
  def wrap(stream, interval_ms \\ @default_interval_ms)
      when is_integer(interval_ms) and interval_ms > 0 do
    Stream.resource(
      fn -> start_worker(stream) end,
      &next(&1, interval_ms),
      &stop_worker/1
    )
  end

  defp start_worker(stream) do
    owner = self()
    tag = make_ref()

    task =
      Task.async(fn ->
        Enum.each(stream, fn event ->
          send(owner, {tag, :event, event})

          receive do
            {^tag, :continue} -> :ok
          end
        end)

        send(owner, {tag, :done})
      end)

    %{tag: tag, task: task}
  end

  defp next(%{tag: tag} = state, interval_ms) do
    receive do
      {^tag, :event, event} ->
        send(state.task.pid, {tag, :continue})
        {[event], state}

      {^tag, :done} ->
        {:halt, state}
    after
      interval_ms -> {[%__MODULE__{}], state}
    end
  end

  defp stop_worker(%{task: task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end
end
