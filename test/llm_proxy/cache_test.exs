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

    def ttl_ms do
      Agent.get(__MODULE__, fn cache -> Map.get(cache, :ttl_ms) end)
    end

    def responses do
      Agent.get(__MODULE__, fn cache ->
        cache
        |> Map.drop([:ttl_ms])
        |> Map.values()
      end)
    end

    @impl LLMProxy.Cache
    def put(key, response, context) do
      Agent.update(__MODULE__, fn cache ->
        cache
        |> Map.put(key, {:hit, response})
        |> Map.put(:ttl_ms, context[:cache_ttl_ms])
      end)
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

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :cache)
      Application.delete_env(:llm_proxy, :cache_policy)
    end)

    :ok
  end

  test "caches non-stream provider responses by normalized request" do
    {:ok, key, _raw_key} =
      Storage.create_key("cache-user", %{capture_content: true})

    assert {:ok, first} = LLMProxy.chat("hello", model: "cache-model", api_key: key)
    refute first.cache_hit
    assert Provider.calls() == 1

    assert {:ok, second} = LLMProxy.chat("hello", model: "cache-model", api_key: key)
    assert second.cache_hit
    assert LLMProxy.Response.to_openai(second) == LLMProxy.Response.to_openai(first)
    assert Provider.calls() == 1
  end

  test "does not send content to a cache for a key without content capture" do
    secret = "seeded-cache-prompt-4bf2"
    {:ok, key, _raw_key} = Storage.create_key("private-cache-user")

    assert {:ok, first} = LLMProxy.chat(secret, model: "cache-model", api_key: key)
    assert {:ok, second} = LLMProxy.chat(secret, model: "cache-model", api_key: key)

    refute first.cache_hit
    refute second.cache_hit
    assert Provider.calls() == 2
    assert Store.responses() == []
  end

  test "per-request metadata can bypass cache without populating it" do
    {:ok, key, _raw_key} =
      Storage.create_key("cache-bypass-user", %{capture_content: true})

    bypass_opts = [model: "cache-model", metadata: %{"no_cache" => true}, api_key: key]
    cached_opts = [model: "cache-model", api_key: key]

    assert {:ok, first} = LLMProxy.chat("hello", bypass_opts)
    refute first.cache_hit

    assert {:ok, second} = LLMProxy.chat("hello", bypass_opts)
    refute second.cache_hit
    assert Provider.calls() == 2

    assert {:ok, third} = LLMProxy.chat("hello", cached_opts)
    refute third.cache_hit
    assert Provider.calls() == 3
  end

  test "cache policy can set ttl context for adapters" do
    Application.put_env(:llm_proxy, :cache_policy, ttl_ms: 60_000)

    {:ok, key, _raw_key} =
      Storage.create_key("cache-ttl-user", %{capture_content: true})

    assert {:ok, response} = LLMProxy.chat("hello", model: "cache-model", api_key: key)
    assert response.cache_ttl_ms == 60_000
    assert Store.ttl_ms() == 60_000
  end

  test "cache policy rejects invalid configured values" do
    Application.put_env(:llm_proxy, :cache_policy, enabled: "yes")

    {:ok, key, _raw_key} =
      Storage.create_key("cache-invalid-enabled-user", %{capture_content: true})

    assert_raise ArgumentError, ~r/enabled must be a boolean/, fn ->
      LLMProxy.chat("hello", model: "cache-model", api_key: key)
    end

    Application.put_env(:llm_proxy, :cache_policy, ttl_ms: 0)

    assert_raise ArgumentError, ~r/ttl_ms must be a positive integer or nil/, fn ->
      LLMProxy.chat("hello", model: "cache-model", api_key: key)
    end
  end

  test "invalid per-request cache ttl metadata is ignored" do
    Application.put_env(:llm_proxy, :cache_policy, ttl_ms: 60_000)

    {:ok, key, _raw_key} =
      Storage.create_key("cache-invalid-metadata-ttl-user", %{capture_content: true})

    assert {:ok, response} =
             LLMProxy.chat("hello",
               model: "cache-model",
               metadata: %{"cache_ttl_ms" => -1},
               api_key: key
             )

    assert response.cache_ttl_ms == 60_000
    assert Store.ttl_ms() == 60_000
  end

  test "cache policy can disable a model" do
    Application.put_env(:llm_proxy, :cache_policy, models: %{"cache-model" => [enabled: false]})

    {:ok, key, _raw_key} =
      Storage.create_key("cache-disabled-user", %{capture_content: true})

    assert {:ok, first} = LLMProxy.chat("hello", model: "cache-model", api_key: key)
    refute first.cache_hit

    assert {:ok, second} = LLMProxy.chat("hello", model: "cache-model", api_key: key)
    refute second.cache_hit
    assert Provider.calls() == 2
  end

  test "does not cache streamed requests" do
    {:ok, key, _raw_key} =
      Storage.create_key("cache-stream-user", %{capture_content: true})

    assert {:ok, first} = LLMProxy.chat("hello", model: "cache-model", stream: true, api_key: key)
    refute first.cache_hit

    assert {:ok, second} =
             LLMProxy.chat("hello", model: "cache-model", stream: true, api_key: key)

    refute second.cache_hit
    assert Provider.calls() == 2
  end
end
