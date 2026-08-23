defmodule LLMProxy.ProviderTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

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
    {:ok, key, _raw_key} = Storage.create_key("local-user", %{capture_content: true})

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

  test "LLMProxy.chat records usage without capturing prompt content by default" do
    secret = "seeded-private-prompt-7c2f"
    {:ok, key, _raw_key} = Storage.create_key("private-local-user")
    handler_id = "private-content-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:llm_proxy, :routing, :attempt, :start],
          [:llm_proxy, :routing, :attempt, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:routing_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert {:ok, response} =
                 LLMProxy.chat(secret, model: "req-llm-provider-model", api_key: key)

        assert response.usage.input_tokens == 4
        assert response.usage.output_tokens == 3
      end)

    refute log =~ secret
    assert Storage.get_messages() == []

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 4
    assert updated_key.output_tokens == 3

    stats = Storage.get_stats()
    assert stats.total_requests == 1
    refute inspect(stats) =~ secret

    assert_receive {:routing_event, [:llm_proxy, :routing, :attempt, :start], _, start_metadata}
    assert_receive {:routing_event, [:llm_proxy, :routing, :attempt, :stop], _, stop_metadata}
    refute inspect(start_metadata) =~ secret
    refute inspect(stop_metadata) =~ secret
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
end
