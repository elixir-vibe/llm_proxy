defmodule LLMProxy.ResourceCleanupStressTest do
  @moduledoc """
  Repeats loopback HTTP work and proves resources return to a bounded baseline.

  The test listener uses two acceptors and sixteen maximum connections. The
  client uses one connection. The inherited BEAM file-descriptor limit must be
  at least 128 so the full test VM has a clear, portable safety margin.
  """

  use ExUnit.Case, async: false

  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.Stream.Event
  alias LLMProxy.TestSupport

  @cycles_per_round 10
  @rounds 3
  @minimum_fd_limit 128
  @port_growth_allowance 2
  @process_growth_allowance 8
  @finch __MODULE__.Finch

  defmodule Tracker do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{active: MapSet.new(), peak: 0} end)

    def enter(tracker, pid) do
      Agent.update(tracker, fn state ->
        active = MapSet.put(state.active, pid)
        %{state | active: active, peak: max(state.peak, MapSet.size(active))}
      end)
    end

    def leave(tracker, pid) do
      Agent.update(tracker, fn state -> %{state | active: MapSet.delete(state.active, pid)} end)
    end

    def status(tracker) do
      Agent.get_and_update(tracker, fn state ->
        active = state.active |> Enum.filter(&Process.alive?/1) |> MapSet.new()
        state = %{state | active: active}
        {state, state}
      end)
    end
  end

  defmodule Provider do
    def name, do: "resource-cleanup"
    def models, do: ["resource-normal", "resource-stream", "resource-cancel"]

    def call(%{"model" => "resource-normal"}, _user_id) do
      track(fn ->
        {:ok,
         Result.response(
           %{
             "id" => "resource-normal",
             "choices" => [
               %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}}
             ],
             "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
           },
           nil
         )}
      end)
    end

    def stream(%{"model" => "resource-stream"}, _user_id),
      do: {:ok, Result.stream(tracked_stream(3), nil)}

    def stream(%{"model" => "resource-cancel"}, _user_id),
      do: {:ok, Result.stream(tracked_stream(:infinity), nil)}

    def extract_usage(response) do
      usage = response["usage"] || %{}
      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)

    defp tracked_stream(limit) do
      Stream.resource(
        fn ->
          tracker = tracker()
          Tracker.enter(tracker, self())
          {tracker, 0, limit}
        end,
        fn
          {tracker, index, limit} when is_integer(limit) and index >= limit ->
            {:halt, {tracker, index, limit}}

          {tracker, index, limit} ->
            if is_integer(limit), do: Process.sleep(2)
            {[event(index, limit)], {tracker, index + 1, limit}}
        end,
        fn {tracker, _index, _limit} -> Tracker.leave(tracker, self()) end
      )
    end

    defp event(index, limit) do
      content = if limit == :infinity, do: String.duplicate("x", 256_000), else: "#{index}"

      Event.new(%{
        "id" => "resource-stream-#{index}",
        "choices" => [%{"index" => 0, "delta" => %{"content" => content}}]
      })
    end

    defp track(fun) do
      tracker = tracker()
      Tracker.enter(tracker, self())

      try do
        fun.()
      after
        Tracker.leave(tracker, self())
      end
    end

    defp tracker, do: Application.fetch_env!(:llm_proxy, :resource_cleanup_tracker)
  end

  setup do
    assert_fd_budget!()
    TestSupport.checkout_repo()
    LLMProxy.Drain.cancel()
    Registry.register(Provider)

    tracker = start_supervised!(Tracker)
    start_supervised!({Finch, name: @finch, pools: %{default: [size: 1, count: 1]}})
    Application.put_env(:llm_proxy, :resource_cleanup_tracker, tracker)

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :resource_cleanup_tracker)
      LLMProxy.Drain.cancel()
    end)

    {:ok, _key, raw_key} = Storage.create_key("resource-cleanup", key_options())
    %{raw_key: raw_key, tracker: tracker}
  end

  test "normal, streaming, and canceled requests return to a bounded baseline", context do
    before_server = settled_snapshot(context.tracker)
    {ref, server} = start_server()

    on_exit(fn ->
      if Process.alive?(server), do: Plug.Cowboy.shutdown(ref)
    end)

    client = client(ref, context.raw_key)
    run_cycle(client, context.tracker)
    server_baseline = settled_snapshot(context.tracker)

    round_snapshots =
      for _round <- 1..@rounds do
        for _cycle <- 1..@cycles_per_round, do: run_cycle(client, context.tracker)
        settled_snapshot(context.tracker)
      end

    first_round = hd(round_snapshots)
    final_round = List.last(round_snapshots)

    Enum.each(round_snapshots, fn snapshot ->
      assert_bounded_growth(server_baseline, snapshot, "warm baseline")
    end)

    assert_bounded_growth(first_round, final_round, "first stress round")

    assert %{active: active, peak: peak} = Tracker.status(context.tracker)
    assert MapSet.size(active) == 0
    assert peak >= 1
    assert_zero_leases()

    monitor = Process.monitor(server)
    assert :ok = Plug.Cowboy.shutdown(ref)
    assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 1_000

    after_server = settled_snapshot(context.tracker)
    assert_bounded_growth(before_server, after_server, "stopped server baseline")
  end

  defp run_cycle(client, tracker) do
    assert %{status: 200, body: %{"choices" => [_choice]}} =
             Req.post!(client.request, json: request_body("resource-normal"))

    assert %{status: 200, body: body} =
             Req.post!(client.request, json: request_body("resource-stream"))

    assert body =~ "[DONE]"
    disconnect_stream(client)
    assert_resources_idle(tracker)
  end

  defp request_body(model) do
    %{
      "model" => model,
      "messages" => [%{"role" => "user", "content" => "resource check"}],
      "stream" => model != "resource-normal"
    }
  end

  defp disconnect_stream(client) do
    body = request_body("resource-cancel") |> Jason.encode!()

    request = [
      "POST /v1/chat/completions HTTP/1.1\r\n",
      "host: 127.0.0.1:#{client.port}\r\n",
      "authorization: Bearer #{client.raw_key}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, client.port, [:binary, active: false], 1_000)

    assert :ok = :gen_tcp.send(socket, request)
    response = receive_sse_chunk(socket, "", 20)
    assert response =~ "HTTP/1.1 200"
    assert response =~ "data:"
    assert :ok = :inet.setopts(socket, linger: {true, 0})
    assert :ok = :gen_tcp.close(socket)
  end

  defp receive_sse_chunk(_socket, response, 0),
    do: flunk("loopback stream did not send an SSE chunk: #{inspect(response)}")

  defp receive_sse_chunk(socket, response, attempts) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        response = response <> data

        if response =~ "data:",
          do: response,
          else: receive_sse_chunk(socket, response, attempts - 1)

      {:error, reason} ->
        flunk("loopback stream closed before an SSE chunk: #{inspect(reason)}")
    end
  end

  defp start_server do
    ref = {__MODULE__, make_ref()}

    {:ok, server} =
      Plug.Cowboy.http(LLMProxy.HTTP.Router, [],
        ref: ref,
        ip: {127, 0, 0, 1},
        port: 0,
        transport_options: [
          num_acceptors: 2,
          max_connections: 16,
          socket_opts: [sndbuf: 16_384]
        ]
      )

    {ref, server}
  end

  defp client(ref, raw_key) do
    {_address, port} = :ranch.get_addr(ref)

    %{
      port: port,
      raw_key: raw_key,
      request:
        Req.new(
          base_url: "http://127.0.0.1:#{port}",
          finch: [name: @finch],
          headers: [
            {"authorization", "Bearer #{raw_key}"},
            {"connection", "close"}
          ],
          receive_timeout: 2_000,
          retry: false,
          url: "/v1/chat/completions"
        )
    }
  end

  defp key_options do
    if limiter_available?() do
      %{budget_limits: [%{"metric" => "concurrent_requests", "max" => 2}]}
    else
      %{}
    end
  end

  defp settled_snapshot(tracker) do
    assert_resources_idle(tracker)
    Process.sleep(50)
    :erlang.garbage_collect()
    %{ports: length(Port.list()), processes: :erlang.system_info(:process_count)}
  end

  defp resources_idle?(tracker) do
    Tracker.status(tracker).active == MapSet.new() and drain_active() == 0 and
      limiter_active() == 0
  end

  defp drain_active, do: LLMProxy.Drain.status().active.total

  defp limiter_active do
    if limiter_available?() do
      module = limiter_module()
      module.status().active
    else
      0
    end
  end

  defp limiter_available?, do: Code.ensure_loaded?(limiter_module())
  defp limiter_module, do: Module.concat(LLMProxy, "ConcurrencyLimiter")

  defp assert_zero_leases do
    assert drain_active() == 0
    assert limiter_active() == 0
  end

  defp assert_bounded_growth(baseline, current, label) do
    assert current.ports <= baseline.ports + @port_growth_allowance,
           "BEAM ports grew from #{baseline.ports} to #{current.ports} after #{label}"

    assert current.processes <= baseline.processes + @process_growth_allowance,
           "BEAM processes grew from #{baseline.processes} to #{current.processes} after #{label}"
  end

  defp assert_fd_budget! do
    limits =
      :erlang.system_info(:check_io)
      |> Enum.map(&Keyword.get(&1, :max_fds))
      |> Enum.filter(&is_integer/1)

    inherited_limit = if limits == [], do: 0, else: Enum.min(limits)

    assert inherited_limit >= @minimum_fd_limit,
           "resource cleanup stress test needs at least #{@minimum_fd_limit} file descriptors; " <>
             "this BEAM inherited #{inherited_limit}"
  end

  defp assert_resources_idle(tracker) do
    unless eventually?(fn -> resources_idle?(tracker) end) do
      flunk(
        "resources did not return to zero: " <>
          inspect(%{
            provider_tasks: provider_task_info(tracker),
            drain_leases: drain_active(),
            concurrency_leases: limiter_active()
          })
      )
    end
  end

  defp provider_task_info(tracker) do
    tracker
    |> Tracker.status()
    |> Map.fetch!(:active)
    |> Enum.map(fn pid ->
      {pid, Process.info(pid, [:current_function, :message_queue_len, :status])}
    end)
  end

  defp eventually?(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts > 0 ->
        Process.sleep(10)
        eventually?(fun, attempts - 1)

      true ->
        false
    end
  end
end
