defmodule LLMProxy.Stream.Heartbeat do
  @moduledoc """
  Adds periodic heartbeat markers while an upstream enumerable is silent.

  The producer is pulled at most one event ahead so slow HTTP clients cannot cause
  unbounded buffering. Consumers render heartbeat markers as SSE comments.
  """

  alias LLMProxy.Telemetry

  @default_interval_ms 15_000

  defmodule Failure do
    @moduledoc "A boundary marker for failures raised by a lazy upstream stream."

    @enforce_keys [:reason]
    defstruct [:reason]

    @type t :: %__MODULE__{reason: term()}
  end

  defstruct []

  @type t :: %__MODULE__{}

  @spec wrap(Enumerable.t()) :: Enumerable.t()
  def wrap(stream), do: wrap(stream, @default_interval_ms, [])

  @spec wrap(Enumerable.t(), pos_integer() | keyword()) :: Enumerable.t()
  def wrap(stream, opts) when is_list(opts), do: wrap(stream, @default_interval_ms, opts)
  def wrap(stream, interval_ms), do: wrap(stream, interval_ms, [])

  @spec wrap(Enumerable.t(), pos_integer(), keyword()) :: Enumerable.t()
  def wrap(stream, interval_ms, opts)
      when is_integer(interval_ms) and interval_ms > 0 and is_list(opts) do
    Stream.resource(
      fn -> start_worker(stream, opts) end,
      &next(&1, interval_ms),
      &stop_worker/1
    )
  end

  defp start_worker(stream, opts) do
    owner = self()
    tag = make_ref()
    telemetry_context = Keyword.get(opts, :telemetry)
    parent_ctx = OpenTelemetry.Ctx.get_current()

    task =
      Task.async(fn ->
        consume = fn -> consume_stream(stream, owner, tag, telemetry_context) end

        if telemetry_context do
          Telemetry.with_stream_span(parent_ctx, telemetry_context, consume)
        else
          consume.()
        end
      end)

    %{tag: tag, task: task, terminal?: false}
  end

  defp consume_stream(stream, owner, tag, telemetry_context) do
    Enum.each(stream, fn event ->
      send(owner, {tag, :event, event})

      receive do
        {^tag, :continue} -> :ok
      end
    end)

    send(owner, {tag, :done})
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      error = Exception.normalize(kind, reason, stacktrace)

      if telemetry_context do
        Telemetry.record_stream_exception(telemetry_context, error, stacktrace)
      end

      send(owner, {tag, :failure, error})
  end

  defp next(%{terminal?: true} = state, _interval_ms), do: {:halt, state}

  defp next(%{tag: tag} = state, interval_ms) do
    receive do
      {^tag, :event, event} ->
        send(state.task.pid, {tag, :continue})
        {[event], state}

      {^tag, :failure, reason} ->
        {[%Failure{reason: reason}], %{state | terminal?: true}}

      {^tag, :done} ->
        {:halt, %{state | terminal?: true}}
    after
      interval_ms -> {[%__MODULE__{}], state}
    end
  end

  defp stop_worker(%{task: task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end
end
