defmodule LLMProxy.Providers.Routing.PerformanceTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Catalog.Deployment
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.Attempt
  alias LLMProxy.Providers.Routing.{Performance, Sample}

  defmodule Provider do
    def name, do: "performance-test"
  end

  setup do
    Performance.reset()
    on_exit(&Performance.reset/0)
    :ok
  end

  test "orders warmed deployments by median attempt duration" do
    request = request(false)
    slow = deployment("slow")
    fast = deployment("fast")

    observe(fast, request, [100, 110, 120])
    observe(slow, request, [400, 500, 600])

    assert [%{upstream_model: "fast"}, %{upstream_model: "slow"}] =
             Performance.order("public", [slow, fast], request)
  end

  test "orders streaming deployments by TTFT rather than client-paced completion time" do
    request = request(true)
    quick_start = deployment("quick-start")
    quick_finish = deployment("quick-finish")

    observe_stream(quick_start, request, [{1_000, 50}, {1_100, 60}, {1_200, 70}])
    observe_stream(quick_finish, request, [{300, 200}, {320, 210}, {340, 220}])

    assert [%{upstream_model: "quick-start"}, %{upstream_model: "quick-finish"}] =
             Performance.order("public", [quick_finish, quick_start], request)
  end

  test "rotates cold deployments so every route is sampled" do
    request = request(false)
    first = deployment("first")
    second = deployment("second")

    assert [%{upstream_model: "first"}, %{upstream_model: "second"}] =
             Performance.order("public", [first, second], request)

    assert [%{upstream_model: "second"}, %{upstream_model: "first"}] =
             Performance.order("public", [first, second], request)
  end

  test "never moves a faster fallback ahead of an earlier order group" do
    request = request(false)
    primary = deployment("primary", order: 1)
    fallback = deployment("fallback", order: 2)

    observe(primary, request, [900, 900, 900])
    observe(fallback, request, [10, 10, 10])

    assert [%{upstream_model: "primary"}, %{upstream_model: "fallback"}] =
             Performance.order("public", [fallback, primary], request)
  end

  test "records stream latency, TTFT, and throughput separately" do
    request = request(true)
    attempt = Attempt.new(deployment("streamed"))
    now = System.monotonic_time(:millisecond)

    Performance.observe(attempt, %Sample{
      operation: request.protocol,
      stream: true,
      outcome: :success,
      duration_ms: 1_500,
      ttft_ms: 300,
      generation_ms: 1_200,
      output_tokens: 120,
      observed_at: now
    })

    assert %{
             success_count: 1,
             median_duration_ms: 1_500,
             median_ttft_ms: 300,
             median_tokens_per_second: 100.0
           } = Performance.stats(attempt, request)
  end

  defp observe(deployment, request, durations) do
    attempt = Attempt.new(deployment)
    now = System.monotonic_time(:millisecond)

    Enum.each(durations, fn duration ->
      Performance.observe(attempt, %Sample{
        operation: request.protocol,
        stream: request.stream,
        outcome: :success,
        duration_ms: duration,
        output_tokens: 0,
        observed_at: now
      })
    end)

    Performance.stats(attempt, request)
  end

  defp observe_stream(deployment, request, timings) do
    attempt = Attempt.new(deployment)
    now = System.monotonic_time(:millisecond)

    Enum.each(timings, fn {duration, ttft} ->
      Performance.observe(attempt, %Sample{
        operation: request.protocol,
        stream: true,
        outcome: :success,
        duration_ms: duration,
        ttft_ms: ttft,
        generation_ms: duration - ttft,
        output_tokens: 10,
        observed_at: now
      })
    end)

    Performance.stats(attempt, request)
  end

  defp deployment(model, opts \\ []) do
    Deployment.new!(Keyword.merge([provider: Provider, upstream_model: model], opts))
  end

  defp request(stream) do
    %Request{
      protocol: :openai_chat,
      model: "public",
      body: %{"model" => "public", "stream" => stream},
      stream: stream
    }
  end
end
