defmodule LLMProxy.CacheTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  defmodule Store do
    @behaviour LLMProxy.Cache

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def stop, do: Agent.stop(__MODULE__)

    @impl LLMProxy.Cache
    def get(key, _context) do
      Agent.get(__MODULE__, fn cache -> Map.get(cache, key) end) || :miss
    end

    @impl LLMProxy.Cache
    def put(key, response, _context) do
      Agent.update(__MODULE__, &Map.put(&1, key, {:hit, response}))
    end
  end

  defmodule Provider do
    def name, do: "cache-provider-test"
    def models, do: ["cache-model"]

    def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
    def stop, do: Agent.stop(__MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1)

    def call(%{"model" => "cache-model"}, _user_id) do
      Agent.update(__MODULE__, &(&1 + 1))

      {:ok,
       Result.response(
         %{
           "id" => "cache-response",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "cached"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1}
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
    start_supervised!(%{id: Store, start: {Store, :start_link, [[]]}})
    start_supervised!(%{id: Provider, start: {Provider, :start_link, [[]]}})
    Registry.register(Provider)
    Application.put_env(:llm_proxy, :cache, Store)

    on_exit(fn -> Application.delete_env(:llm_proxy, :cache) end)

    :ok
  end

  test "caches non-stream provider responses by normalized request" do
    {:ok, key, _raw_key} = Storage.create_key("cache-user")

    assert {:ok, first} = LLMProxy.chat("hello", model: "cache-model", api_key: key)
    refute first.cache_hit
    assert Provider.calls() == 1

    assert {:ok, second} = LLMProxy.chat("hello", model: "cache-model", api_key: key)
    assert second.cache_hit
    assert second.body == first.body
    assert Provider.calls() == 1
  end

  test "does not cache streamed requests" do
    {:ok, key, _raw_key} = Storage.create_key("cache-stream-user")

    assert {:ok, first} = LLMProxy.chat("hello", model: "cache-model", stream: true, api_key: key)
    refute first.cache_hit

    assert {:ok, second} =
             LLMProxy.chat("hello", model: "cache-model", stream: true, api_key: key)

    refute second.cache_hit
    assert Provider.calls() == 2
  end
end
