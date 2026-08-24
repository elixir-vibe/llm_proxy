defmodule LLMProxy.Providers.Routing.Performance do
  @moduledoc """
  Keeps bounded, per-deployment performance observations for latency-aware routing.

  State is intentionally node-local and ephemeral. Durable request accounting remains
  in storage, while this process only serves the routing hot path.
  """

  use GenServer

  alias LLMProxy.Catalog.Deployment
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.Attempt
  alias LLMProxy.Providers.Routing.Sample
  alias LLMProxy.Telemetry

  @sample_size 20
  @minimum_samples 3
  @max_age_ms :timer.minutes(5)
  @near_best_ratio 0.10

  @type stats :: %{
          success_count: non_neg_integer(),
          error_count: non_neg_integer(),
          median_duration_ms: number() | nil,
          median_ttft_ms: number() | nil,
          median_tokens_per_second: number() | nil,
          updated_at: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, empty_state(), Keyword.put_new(opts, :name, __MODULE__))

  @spec observe(Attempt.t(), Sample.t(), atom() | nil) :: :ok
  def observe(%Attempt{} = attempt, %Sample{} = sample, event \\ nil) do
    event = event || if(sample.stream, do: :stream_attempt, else: :attempt)

    Telemetry.emit(
      [:routing, event, :complete],
      attempt,
      measurements(sample),
      %{operation: sample.operation, stream: sample.stream, outcome: sample.outcome}
    )

    GenServer.cast(__MODULE__, {:observe, observation_key(attempt, sample), sample})
  end

  @spec order(String.t(), [Deployment.t()], Request.t()) :: [Deployment.t()]
  def order(model, deployments, %Request{} = request) when is_binary(model) do
    GenServer.call(__MODULE__, {:order, model, deployments, request})
  end

  @spec stats(Attempt.t(), Request.t()) :: stats()
  def stats(%Attempt{} = attempt, %Request{} = request) do
    GenServer.call(__MODULE__, {:stats, request_key(attempt, request)})
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_cast({:observe, key, sample}, state) do
    entry = Map.get(state.observations, key, empty_entry())

    entry =
      case sample.outcome do
        :success ->
          samples = [sample | entry.samples] |> Enum.take(@sample_size)
          %{entry | samples: samples, updated_at: sample.observed_at}

        :error ->
          %{entry | error_count: entry.error_count + 1, updated_at: sample.observed_at}
      end

    {:noreply, put_in(state, [:observations, key], entry)}
  end

  @impl GenServer
  def handle_call({:order, model, deployments, request}, _from, state) do
    {ordered, decisions} = order_groups(model, deployments, request, state)
    {:reply, ordered, %{state | decisions: decisions}}
  end

  def handle_call({:stats, key}, _from, state) do
    entry = Map.get(state.observations, key, empty_entry())
    {:reply, summarize(entry, now_ms()), state}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, empty_state()}

  defp order_groups(model, deployments, request, state) do
    deployments
    |> Enum.group_by(& &1.order)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_reduce(state.decisions, fn {order, group}, decisions ->
      decision_key = {model, order, request.protocol, request.stream == true}
      offset = Map.get(decisions, decision_key, 0)
      ordered = order_group(group, request, state.observations, offset)
      {ordered, Map.put(decisions, decision_key, offset + 1)}
    end)
    |> then(fn {groups, decisions} -> {List.flatten(groups), decisions} end)
  end

  defp order_group(deployments, request, observations, offset) do
    now = now_ms()

    ranked =
      Enum.map(deployments, fn deployment ->
        attempt = Attempt.new(deployment)
        entry = Map.get(observations, request_key(attempt, request), empty_entry())
        {deployment, summarize(entry, now)}
      end)

    {cold, warm} =
      Enum.split_with(ranked, fn {_deployment, stats} ->
        stats.success_count < @minimum_samples or stale?(stats.updated_at, now)
      end)

    case cold do
      [] ->
        order_warm(warm, request.stream == true, offset)

      _cold ->
        rotate(Enum.map(cold, &elem(&1, 0)), offset) ++
          order_warm(warm, request.stream == true, offset)
    end
  end

  defp order_warm([], _stream, _offset), do: []

  defp order_warm(ranked, stream, offset) do
    sorted = Enum.sort_by(ranked, fn {_deployment, stats} -> routing_score(stats, stream) end)
    best_latency = sorted |> hd() |> elem(1) |> routing_latency(stream)
    threshold = best_latency * (1 + @near_best_ratio)

    {near_best, rest} =
      Enum.split_while(sorted, fn {_deployment, stats} ->
        routing_latency(stats, stream) <= threshold
      end)

    rotate(Enum.map(near_best, &elem(&1, 0)), offset) ++ Enum.map(rest, &elem(&1, 0))
  end

  defp routing_score(stats, true) do
    {
      routing_latency(stats, true),
      stats.median_duration_ms || :infinity,
      negate(stats.median_tokens_per_second)
    }
  end

  defp routing_score(stats, false) do
    {
      routing_latency(stats, false),
      negate(stats.median_tokens_per_second)
    }
  end

  defp routing_latency(stats, true),
    do: stats.median_ttft_ms || stats.median_duration_ms || :infinity

  defp routing_latency(stats, false), do: stats.median_duration_ms || :infinity

  defp summarize(entry, now) do
    samples = Enum.reject(entry.samples, &(now - &1.observed_at > @max_age_ms))

    %{
      success_count: length(samples),
      error_count: entry.error_count,
      median_duration_ms: samples |> Enum.map(& &1.duration_ms) |> median(),
      median_ttft_ms: samples |> Enum.map(& &1.ttft_ms) |> Enum.reject(&is_nil/1) |> median(),
      median_tokens_per_second:
        samples |> Enum.map(&Sample.tokens_per_second/1) |> Enum.reject(&is_nil/1) |> median(),
      updated_at: if(samples == [], do: nil, else: entry.updated_at)
    }
  end

  defp measurements(sample) do
    %{duration_ms: sample.duration_ms}
    |> put_measurement(:output_tokens, sample.output_tokens)
    |> put_measurement(:ttft_ms, sample.ttft_ms)
    |> put_measurement(:generation_ms, sample.generation_ms)
    |> put_measurement(:tokens_per_second, Sample.tokens_per_second(sample))
  end

  defp put_measurement(measurements, _key, nil), do: measurements
  defp put_measurement(measurements, key, value), do: Map.put(measurements, key, value)

  defp observation_key(attempt, sample),
    do: {Attempt.key(attempt), sample.operation, sample.stream}

  defp request_key(attempt, request),
    do: {Attempt.key(attempt), request.protocol, request.stream == true}

  defp stale?(nil, _now), do: true
  defp stale?(updated_at, now), do: now - updated_at > @max_age_ms

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp rotate([], _offset), do: []

  defp rotate(items, offset) do
    {left, right} = Enum.split(items, rem(offset, length(items)))
    right ++ left
  end

  defp negate(nil), do: 0
  defp negate(value), do: -value

  defp empty_entry, do: %{samples: [], error_count: 0, updated_at: nil}
  defp empty_state, do: %{observations: %{}, decisions: %{}}
  defp now_ms, do: System.monotonic_time(:millisecond)
end
