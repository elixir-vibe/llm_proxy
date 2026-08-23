defmodule LLMProxy.ProviderTest do
  use ExUnit.Case

  alias LLMProxy.{ConcurrencyLimiter, Limit}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.Stream.Event
  alias LLMProxy.TestSupport

  defmodule Provider do
    def name, do: "req-llm-provider-test"
    def models, do: ["req-llm-provider-model"]

    def call(%{"model" => "req-llm-provider-model", "messages" => _messages}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "req-llm-provider-test-1",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "hello from provider"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 3}
         },
         nil
       )}
    end

    def stream(%{"model" => "req-llm-provider-model", "stream" => true}, _user_id) do
      stream = [
        Event.new(%{"choices" => [%{"delta" => %{"content" => "hello"}}]},
          usage: LLMProxy.Usage.new(4, 0)
        ),
        Event.new(%{"choices" => [%{"delta" => %{"content" => " stream"}}]},
          usage: LLMProxy.Usage.new(4, 3)
        )
      ]

      {:ok, Result.stream(stream, nil)}
    end

    def extract_usage(response) do
      usage = response["usage"] || %{}
      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)
  end

  setup do
    TestSupport.checkout_repo()
    Registry.register(Provider)
    ReqLLM.Providers.register(LLMProxy.Provider)
    :ok
  end

  test "LLMProxy.chat calls Provider in-process and records usage" do
    {:ok, key, _raw_key} = Storage.create_key("local-user")

    assert {:ok, response} =
             LLMProxy.chat("hello", model: "req-llm-provider-model", api_key: key)

    assert LLMProxy.Response.to_openai(response)["model"] == "req-llm-provider-model"
    assert response.usage.input_tokens == 4
    assert response.usage.output_tokens == 3

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 4
    assert updated_key.output_tokens == 3

    assert [%{user_message: "hello", input_tokens: 4, output_tokens: 3}] =
             Storage.get_messages()
  end

  test "Provider.stream returns guarded streams and records usage after consumption" do
    {:ok, key, _raw_key} = Storage.create_key("local-stream-user")

    request = %Request{
      protocol: :openai_chat,
      model: "req-llm-provider-model",
      stream: true,
      body: %{"model" => "req-llm-provider-model", "messages" => []},
      messages: []
    }

    assert {:ok, %Result{stream: stream}} =
             LLMProxy.Provider.stream(request, key, route: :chat, trace_id: "trace-stream")

    assert [%Event{}, %Event{}] = Enum.to_list(stream)

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 4
    assert updated_key.output_tokens == 3
  end

  test "ReqLLM provider handles calls without HTTP" do
    {:ok, _key, raw_key} = Storage.create_key("req-llm-user")

    model = %{
      id: "req-llm-provider-model",
      provider: :llm_proxy,
      model: "req-llm-provider-model"
    }

    assert {:ok, response} = ReqLLM.Generation.generate_text(model, "hello", api_key: raw_key)
    assert ReqLLM.Response.text(response) == "hello from provider"
    assert response.usage.input_tokens == 4

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 4
    assert updated_key.output_tokens == 3
  end

  test "local and ReqLLM calls share the concurrent-request limit" do
    {:ok, key, raw_key} =
      Storage.create_key("concurrent-provider-user", %{
        budget_limits: [Limit.concurrent_requests(1)]
      })

    assert {:ok, lease} = ConcurrencyLimiter.acquire(key)
    on_exit(fn -> ConcurrencyLimiter.release(lease) end)

    assert {:error, {:concurrency_limit, 1}} =
             LLMProxy.chat("hello", model: "req-llm-provider-model", api_key: key)

    model = %{
      id: "req-llm-provider-model",
      provider: :llm_proxy,
      model: "req-llm-provider-model"
    }

    assert {:error,
            %ReqLLM.Error.API.Request{
              status: 429,
              response_body: %{
                "error" => %{
                  "code" => "rate_limit_error",
                  "message" => message
                }
              }
            }} = ReqLLM.Generation.generate_text(model, "hello", api_key: raw_key)

    assert message == ConcurrencyLimiter.error_message()
  end
end
