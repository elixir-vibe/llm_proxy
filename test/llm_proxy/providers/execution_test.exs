defmodule LLMProxy.Providers.ExecutionTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.Attempt
  alias LLMProxy.Providers.CircuitBreaker
  alias LLMProxy.Providers.{Execution, Result}
  alias LLMProxy.Stream.Event

  defmodule SuccessProvider do
    def name, do: "success"
    def call(_body, _user_id), do: {:ok, Result.response(%{"ok" => true}, nil)}
    def stream(_body, _user_id), do: {:ok, Result.stream([], nil)}
  end

  defmodule FailProvider do
    def name, do: "fail"
    def call(_body, _user_id), do: {:error, Result.error("server error", 500, nil)}
    def stream(_body, _user_id), do: {:error, Result.error("server error", 500, nil)}
  end

  defmodule ConnectFailProvider do
    def name, do: "connect-fail"

    def call(_body, _user_id),
      do: {:error, Result.error("connection refused", 502, nil, replay_safety: :safe)}

    def stream(_body, _user_id),
      do: {:error, Result.error("connection refused", 502, nil, replay_safety: :safe)}
  end

  defmodule SlowProvider do
    def name, do: "slow"

    def call(_body, _user_id) do
      Process.sleep(100)
      {:ok, Result.response(%{"late" => true}, nil)}
    end
  end

  defmodule SecondSafeFailProvider do
    def name, do: "second-safe-fail"

    def call(_body, user_id) do
      send(user_id, :second_attempt)
      {:error, Result.error("not dispatched", 503, nil, replay_safety: :safe)}
    end
  end

  defmodule CountingSuccessProvider do
    def name, do: "counting-success"

    def call(_body, user_id) do
      send(user_id, :third_attempt)
      {:ok, Result.response(%{"ok" => true}, nil)}
    end
  end

  defmodule PartialStreamProvider do
    def name, do: "partial-stream"

    def stream(_body, _user_id) do
      tail = Stream.map([:failure], fn _ -> raise "stream failed after output" end)
      {:ok, Result.stream(Stream.concat([Event.new(%{"partial" => true})], tail), nil)}
    end
  end

  defmodule RaisingProvider do
    def name, do: "raising"

    def call(_body, _user_id) do
      raise "provider failed with headers: authorization=Bearer secret"
    end
  end

  defmodule RateLimitedProvider do
    def name, do: "limited"
    def call(_body, _user_id), do: {:error, Result.error("rate limited", 429, nil)}
    def stream(_body, _user_id), do: {:error, Result.error("rate limited", 429, nil)}
  end

  defmodule RetryAfterProvider do
    def name, do: "retry-after"

    def call(_body, _user_id),
      do: {:error, Result.error("rate limited", 429, nil, retry_after_ms: 123)}

    def stream(_body, _user_id),
      do: {:error, Result.error("rate limited", 429, nil, retry_after_ms: 123)}
  end

  defmodule AuthErrorProvider do
    def name, do: "auth_fail"
    def call(_body, _user_id), do: {:error, Result.error("unauthorized", 401, nil)}
    def stream(_body, _user_id), do: {:error, Result.error("unauthorized", 401, nil)}
  end

  defmodule NativeAnthropicProvider do
    def name, do: "native-anthropic"
    def native_protocol, do: :anthropic

    def call(
          %{"max_tokens" => 4096, "messages" => [%{"role" => "user", "content" => "hello"}]},
          _user_id
        ),
        do: {:ok, Result.response(%{"ok" => "anthropic"}, nil)}

    def stream(%{"max_tokens" => 4096, "stream" => true}, _user_id),
      do: {:ok, Result.stream([], nil)}
  end

  defmodule FallbackProvider do
    def name, do: "fallback"
    def models, do: ["fallback-model"]

    def call(%{"model" => "fallback-model"}, _user_id),
      do: {:ok, Result.response(%{"ok" => "fallback"}, nil)}

    def stream(%{"model" => "fallback-model"}, _user_id),
      do: {:ok, Result.stream([Event.new(%{"ok" => true})], nil)}
  end

  defmodule NativeBodyProvider do
    def name, do: "native-body"

    def call_native(%{"model" => "upstream-native"}, _user_id),
      do: {:ok, Result.response(%{"ok" => true}, nil)}

    def stream_native(%{"model" => "upstream-native", "stream" => true}, _user_id),
      do: {:ok, Result.stream([], nil)}
  end

  setup do
    LLMProxy.Providers.Registry.register(FallbackProvider)
    CircuitBreaker.reset()

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :fallbacks)
      Application.delete_env(:llm_proxy, :max_retries)
      Application.delete_env(:llm_proxy, :replay_policy)
      CircuitBreaker.reset()
    end)

    :ok
  end

  describe "call/4 with no fallbacks" do
    test "returns success on first try" do
      assert {:ok, %Result{response: %{"ok" => true}, provider: SuccessProvider, model: "m"}} =
               Execution.call(SuccessProvider, request("m"), "user", "m")
    end

    test "returns error when provider fails with non-retryable error" do
      assert {:error, %Result{status: 401}} =
               Execution.call(AuthErrorProvider, request("m"), "user", "m")
    end

    test "returns error when provider fails with retryable error but no fallbacks" do
      assert {:error, %Result{status: 500}} =
               Execution.call(FailProvider, request("m"), "user", "m")
    end

    test "does not expose raised provider internals" do
      attempt = %Attempt{provider: RaisingProvider, model: "m", timeout_ms: nil}

      assert {:error, %Result{status: 500, error: "Internal provider execution failed"}} =
               Execution.call_attempts([attempt], request("m"), "user")
    end
  end

  describe "call/4 protocol conversion" do
    test "converts OpenAI chat bodies to provider-native request format" do
      assert {:ok, %Result{response: %{"ok" => "anthropic"}, provider: NativeAnthropicProvider}} =
               Execution.call(
                 NativeAnthropicProvider,
                 request("claude"),
                 "user",
                 "claude"
               )
    end
  end

  describe "call/4 with fallbacks" do
    test "compatibility policy permits fallback after uncertain server errors" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})
      Application.put_env(:llm_proxy, :replay_policy, :allow_uncertain)

      assert {:ok,
              %{
                response: %{"ok" => "fallback"},
                provider: FallbackProvider,
                model: "fallback-model"
              }} =
               Execution.call(FailProvider, request("m"), "user", "m")
    end

    test "does not replay uncertain server errors by default" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})

      assert {:error, %Result{status: 500, provider: FailProvider}} =
               Execution.call(FailProvider, request("m"), "user", "m")
    end

    test "replays clear connect failures" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})

      assert {:ok, %Result{provider: FallbackProvider}} =
               Execution.call(ConnectFailProvider, request("m"), "user", "m")
    end

    test "does not replay a timeout without explicit uncertain replay" do
      attempts = [
        %Attempt{provider: SlowProvider, model: "m", timeout_ms: 1},
        {FallbackProvider, "fallback-model"}
      ]

      assert {:error, %Result{status: 504, provider: SlowProvider}} =
               Execution.call_attempts(attempts, request("m"), "user")
    end

    test "enforces the provider dispatch budget" do
      Application.put_env(:llm_proxy, :max_retries, 1)

      attempts = [
        %Attempt{
          provider: ConnectFailProvider,
          model: "m",
          failure_threshold: 10
        },
        %Attempt{
          provider: SecondSafeFailProvider,
          model: "m",
          failure_threshold: 10
        },
        {CountingSuccessProvider, "m"}
      ]

      assert {:error, %Result{provider: SecondSafeFailProvider}} =
               Execution.call_attempts(attempts, request("m"), self())

      assert_received :second_attempt
      refute_received :third_attempt
    end

    test "open-circuit skips do not consume the dispatch budget" do
      Application.put_env(:llm_proxy, :max_retries, 0)
      handler_id = {__MODULE__, self(), :circuit_skip}
      parent = self()

      :telemetry.attach(
        handler_id,
        [:llm_proxy, :routing, :attempt, :skip],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      skipped = %Attempt{
        provider: ConnectFailProvider,
        model: "m",
        failure_threshold: 1,
        cooldown_ms: 10_000
      }

      CircuitBreaker.failure(skipped)

      assert {:ok, %Result{provider: CountingSuccessProvider}} =
               Execution.call_attempts(
                 [skipped, {CountingSuccessProvider, "m"}],
                 request("m"),
                 self()
               )

      assert_received :third_attempt

      assert_receive {:telemetry, [:llm_proxy, :routing, :attempt, :skip], %{}, metadata}
      assert metadata.attempt_number == 0
      assert metadata.max_attempts == 1
      assert metadata.replay_safety == :safe
      assert metadata.replay_decision == :retry
      assert metadata.replay_reason == :circuit_open
    end

    test "emits bounded content-free replay metadata" do
      handler_id = {__MODULE__, self(), :replay_metadata}
      parent = self()

      :telemetry.attach(
        handler_id,
        [:llm_proxy, :routing, :attempt, :exception],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %Result{provider: FallbackProvider}} =
               Execution.call_attempts(
                 [
                   {RateLimitedProvider, "seeded-secret-model"},
                   {FallbackProvider, "fallback-model"}
                 ],
                 request("seeded-secret-request"),
                 "user"
               )

      assert_receive {:telemetry, _, %{status: 429}, metadata}
      assert metadata.attempt_number == 1
      assert metadata.max_attempts == 2
      assert metadata.replay_safety == :safe
      assert metadata.replay_decision == :retry
      assert metadata.replay_reason == :safe_failure
      refute inspect(metadata) =~ "seeded-secret-request"
    end

    test "tries fallbacks on rate limits" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})

      assert {:ok,
              %{
                response: %{"ok" => "fallback"},
                provider: FallbackProvider,
                model: "fallback-model"
              }} =
               Execution.call(RateLimitedProvider, request("m"), "user", "m")
    end

    test "uses retry-after as circuit breaker cooldown" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})

      attempt = %Attempt{provider: RetryAfterProvider, model: "m", failure_threshold: 1}

      assert {:ok, %Result{provider: FallbackProvider}} =
               Execution.call_attempts(
                 [attempt, {FallbackProvider, "fallback-model"}],
                 request("m"),
                 "user"
               )

      assert %CircuitBreaker{state: :open, cooldown_ms: 123} = CircuitBreaker.status(attempt)
    end
  end

  describe "native attempts" do
    test "reports unsupported protocol skips without consuming the budget" do
      handler_id = {__MODULE__, self(), :unsupported_native_skip}
      parent = self()

      :telemetry.attach(
        handler_id,
        [:llm_proxy, :routing, :native_attempt, :skip],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %Result{provider: NativeBodyProvider}} =
               Execution.call_native_attempts(
                 [
                   {SuccessProvider, "unsupported-native"},
                   {NativeBodyProvider, "upstream-native"}
                 ],
                 request("public-alias"),
                 "user",
                 "Native API"
               )

      assert_receive {:telemetry, [:llm_proxy, :routing, :native_attempt, :skip], %{}, metadata}
      assert metadata.attempt_number == 0
      assert metadata.max_attempts == 2
      assert metadata.replay_safety == :safe
      assert metadata.replay_decision == :retry
      assert metadata.replay_reason == :unsupported_protocol
    end

    test "send the upstream attempt model in native bodies" do
      assert {:ok, %Result{response: %{"ok" => true}, provider: NativeBodyProvider}} =
               Execution.call_native_attempts(
                 [%Attempt{provider: NativeBodyProvider, model: "upstream-native"}],
                 request("public-alias"),
                 "user",
                 "Native API"
               )
    end

    test "emits native stream telemetry on the native stream event family" do
      handler_id = {__MODULE__, self(), :native_stream_telemetry}
      parent = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:llm_proxy, :routing, :native_stream_attempt, :start],
          [:llm_proxy, :routing, :native_stream_attempt, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %Result{stream: [], provider: NativeBodyProvider}} =
               Execution.stream_native_attempts(
                 [%Attempt{provider: NativeBodyProvider, model: "upstream-native"}],
                 stream_request("public-alias"),
                 "user",
                 "Native API"
               )

      assert_receive {:telemetry, [:llm_proxy, :routing, :native_stream_attempt, :start], _, _}
      assert_receive {:telemetry, [:llm_proxy, :routing, :native_stream_attempt, :stop], _, _}
    end
  end

  describe "stream/4 with no fallbacks" do
    test "returns success on first try" do
      assert {:ok, %Result{stream: [], provider: SuccessProvider, model: "m"}} =
               Execution.stream(SuccessProvider, request("m"), "user", "m")
    end

    test "returns error on non-retryable error" do
      assert {:error, %Result{status: 401}} =
               Execution.stream(AuthErrorProvider, request("m"), "user", "m")
    end
  end

  describe "stream/4 with fallbacks" do
    test "replays clear stream setup connect failures" do
      assert {:ok, %Result{provider: FallbackProvider}} =
               Execution.stream_attempts(
                 [
                   {ConnectFailProvider, "m"},
                   {FallbackProvider, "fallback-model"}
                 ],
                 stream_request("m"),
                 "user"
               )
    end

    test "compatibility policy permits fallback streams after uncertain errors" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})
      Application.put_env(:llm_proxy, :replay_policy, :allow_uncertain)

      assert {:ok,
              %{
                stream: [%Event{data: %{"ok" => true}}],
                provider: FallbackProvider,
                model: "fallback-model"
              }} =
               Execution.stream(FailProvider, request("m"), "user", "m")
    end

    test "never falls back after stream output becomes visible" do
      assert {:ok, %Result{provider: PartialStreamProvider, stream: stream}} =
               Execution.stream_attempts(
                 [
                   {PartialStreamProvider, "m"},
                   {FallbackProvider, "fallback-model"}
                 ],
                 stream_request("m"),
                 "user"
               )

      assert_raise RuntimeError, "stream failed after output", fn -> Enum.to_list(stream) end
    end
  end

  defp stream_request(model) do
    request = request(model)
    %{request | stream: true, body: Map.put(request.body, "stream", true)}
  end

  defp request(model) do
    {:ok, request} =
      Request.parse(:openai_chat, %{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "max_tokens" => 4096
      })

    request
  end
end
