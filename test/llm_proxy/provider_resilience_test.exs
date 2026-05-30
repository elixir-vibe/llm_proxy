defmodule LLMProxy.ProviderResilienceTest do
  use ExUnit.Case

  alias LLMProxy.Catalog
  alias LLMProxy.CircuitBreaker
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Routing.Attempt
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  defmodule TimeoutProvider do
    def name, do: "timeout-routing-test"
    def models, do: ["slow-model", "fast-model"]

    def call(%{"model" => "slow-model"}, _user_id) do
      Process.sleep(50)
      {:ok, Result.response(%{"usage" => %{}}, nil)}
    end

    def call(%{"model" => "fast-model"}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "timeout-fallback",
           "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
           "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
         },
         nil
       )}
    end

    def extract_usage(response) do
      usage = response["usage"] || %{}
      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)
  end

  defmodule CircuitProvider do
    def name, do: "circuit-routing-test"
    def models, do: ["broken-model", "healthy-model"]

    def call(%{"model" => "broken-model"}, _user_id),
      do: {:error, Result.error("broken", 500, nil)}

    def call(%{"model" => "healthy-model"}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "circuit-fallback",
           "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
           "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 3}
         },
         nil
       )}
    end

    def extract_usage(response) do
      usage = response["usage"] || %{}
      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)
  end

  setup do
    TestSupport.checkout_repo()
    CircuitBreaker.reset()
    Catalog.load([])
    Registry.register(TimeoutProvider)
    Registry.register(CircuitProvider)

    on_exit(fn ->
      Catalog.load([])
      CircuitBreaker.reset()
    end)

    :ok
  end

  test "deployment timeout falls back to next deployment" do
    Catalog.put_model(%{
      name: "timeout-model",
      deployments: [
        %{provider: TimeoutProvider, upstream_model: "slow-model", timeout_ms: 1},
        %{provider: TimeoutProvider, upstream_model: "fast-model"}
      ]
    })

    {:ok, key, _raw_key} = Storage.create_key("timeout-user")

    assert {:ok, response} = LLMProxy.chat("hello", model: "timeout-model", api_key: key)
    assert response.model == "fast-model"
    assert response.body["model"] == "fast-model"
  end

  test "circuit breaker opens and skips unhealthy deployments" do
    Catalog.put_model(%{
      name: "circuit-model",
      deployments: [
        %{
          provider: CircuitProvider,
          upstream_model: "broken-model",
          failure_threshold: 1,
          cooldown_ms: 1_000
        },
        %{provider: CircuitProvider, upstream_model: "healthy-model"}
      ]
    })

    {:ok, key, _raw_key} = Storage.create_key("circuit-user")

    assert {:ok, first} = LLMProxy.chat("hello", model: "circuit-model", api_key: key)
    assert first.model == "healthy-model"

    attempt = %Attempt{provider: CircuitProvider, model: "broken-model"}
    assert %CircuitBreaker{state: :open} = CircuitBreaker.status(attempt)

    assert {:ok, second} = LLMProxy.chat("hello", model: "circuit-model", api_key: key)
    assert second.model == "healthy-model"
  end

  test "provider responses include trace id" do
    Catalog.put_model(%{
      name: "trace-model",
      deployments: [%{provider: CircuitProvider, upstream_model: "healthy-model"}]
    })

    {:ok, key, _raw_key} = Storage.create_key("trace-user")

    assert {:ok, response} = LLMProxy.chat("hello", model: "trace-model", api_key: key)
    assert is_binary(response.trace_id)
  end
end
