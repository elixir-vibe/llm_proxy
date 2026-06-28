defmodule LLMProxy.ProviderResilienceTest do
  use ExUnit.Case

  alias LLMProxy.Catalog
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.CircuitBreaker
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Providers.Routing.Attempt
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

  defmodule RecoveryProvider do
    def name, do: "recovery-routing-test"
    def models, do: ["recovery-model"]

    def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)

    def call(%{"model" => "recovery-model"}, _user_id) do
      Agent.get_and_update(__MODULE__, fn
        0 -> {{:error, Result.error("temporary", 500, nil)}, 1}
        count -> {ok_response(), count + 1}
      end)
    end

    def extract_usage(response) do
      usage = response["usage"] || %{}
      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)

    defp ok_response do
      {:ok,
       Result.response(
         %{
           "id" => "recovered",
           "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
           "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
         },
         nil
       )}
    end
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
    start_supervised!(%{id: RecoveryProvider, start: {RecoveryProvider, :start_link, [[]]}})
    Registry.register(TimeoutProvider)
    Registry.register(CircuitProvider)
    Registry.register(RecoveryProvider)

    on_exit(fn ->
      Catalog.load([])
      CircuitBreaker.reset()
    end)

    :ok
  end

  test "deployment timeout falls back to next deployment" do
    Catalog.put_model(
      model("timeout-model", [
        deployment(TimeoutProvider, "slow-model", timeout_ms: 1),
        deployment(TimeoutProvider, "fast-model")
      ])
    )

    {:ok, key, _raw_key} = Storage.create_key("timeout-user")

    assert {:ok, response} = LLMProxy.chat("hello", model: "timeout-model", api_key: key)
    assert response.model == "fast-model"
    assert response.body["model"] == "fast-model"
  end

  test "circuit breaker opens and skips unhealthy deployments" do
    Catalog.put_model(
      model("circuit-model", [
        deployment(CircuitProvider, "broken-model", failure_threshold: 1, cooldown_ms: 1_000),
        deployment(CircuitProvider, "healthy-model")
      ])
    )

    {:ok, key, _raw_key} = Storage.create_key("circuit-user")

    assert {:ok, first} = LLMProxy.chat("hello", model: "circuit-model", api_key: key)
    assert first.model == "healthy-model"

    attempt = %Attempt{provider: CircuitProvider, model: "broken-model"}
    assert %CircuitBreaker{state: :open} = CircuitBreaker.status(attempt)

    assert {:ok, second} = LLMProxy.chat("hello", model: "circuit-model", api_key: key)
    assert second.model == "healthy-model"
  end

  test "half-open circuit closes after successful cooldown probe" do
    Catalog.put_model(
      model("recovery-circuit-model", [
        deployment(RecoveryProvider, "recovery-model", failure_threshold: 1, cooldown_ms: 0)
      ])
    )

    {:ok, key, _raw_key} = Storage.create_key("recovery-user")

    assert {:error, {:provider, %Result{status: 500}}} =
             LLMProxy.chat("hello", model: "recovery-circuit-model", api_key: key)

    attempt = %Attempt{provider: RecoveryProvider, model: "recovery-model"}
    assert %CircuitBreaker{state: :open} = CircuitBreaker.status(attempt)

    assert {:ok, response} = LLMProxy.chat("hello", model: "recovery-circuit-model", api_key: key)
    assert response.model == "recovery-model"
    assert %CircuitBreaker{state: :closed} = CircuitBreaker.status(attempt)
  end

  test "provider responses include trace id" do
    Catalog.put_model(model("trace-model", [deployment(CircuitProvider, "healthy-model")]))

    {:ok, key, _raw_key} = Storage.create_key("trace-user")

    assert {:ok, response} = LLMProxy.chat("hello", model: "trace-model", api_key: key)
    assert is_binary(response.trace_id)
  end

  defp model(name, deployments), do: Model.new!(name: name, deployments: deployments)

  defp deployment(provider, upstream_model, opts \\ []) do
    Deployment.new!(Keyword.merge([provider: provider, upstream_model: upstream_model], opts))
  end
end
