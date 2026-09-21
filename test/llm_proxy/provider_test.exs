defmodule LLMProxy.ProviderTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias LLMProxy.{Catalog, ConcurrencyLimiter, Limit}
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.Stream.Event
  alias LLMProxy.TestSupport

  defmodule Provider do
    alias LLMProxy.Protocol.Request

    def name, do: "req-llm-provider-test"

    def models,
      do: [
        "req-llm-provider-model",
        "req-llm-provider-error-model",
        "req-llm-provider-blocked-model",
        "req-llm-provider-rich-model"
      ]

    def call(%{"model" => "req-llm-provider-model", "messages" => _messages} = body, _user_id) do
      {:ok, %Request{messages: [_message]}} = Request.parse(:openai_chat, body)

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

    def stream(%{"model" => model, "stream" => true} = body, _user_id) do
      {:ok, %Request{}} = Request.parse(:openai_chat, body)
      {:ok, Result.stream(stream_for(model), nil)}
    end

    def extract_usage(response) do
      usage = response["usage"] || %{}
      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)

    defp stream_for("req-llm-provider-model") do
      [
        Event.openai_chat_content_delta("req-llm-provider-model", "hello"),
        Event.openai_chat_content_delta("req-llm-provider-model", " stream"),
        Event.openai_chat_terminal(
          "req-llm-provider-model",
          :stop,
          LLMProxy.Usage.new(4, 3)
        )
      ]
    end

    defp stream_for("req-llm-provider-error-model") do
      [
        Event.openai_chat_content_delta("req-llm-provider-error-model", "partial"),
        Event.new(%{"error" => %{"message" => "stream failed", "status" => 502}},
          kind: :error
        )
      ]
    end

    defp stream_for("req-llm-provider-blocked-model") do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})

      Stream.repeatedly(fn ->
        send(test_pid, :provider_waiting)

        receive do
          {:provider_chunk, text} ->
            Event.openai_chat_content_delta("req-llm-provider-blocked-model", text)
        end
      end)
    end

    defp stream_for("req-llm-provider-rich-model") do
      [
        Event.new(
          %{
            "choices" => [
              %{"index" => 0, "delta" => %{"reasoning_content" => "thinking"}}
            ]
          },
          kind: :reasoning
        ),
        Event.openai_chat_tool_call_delta(
          0,
          "call_1",
          "lookup",
          %{"query" => "value"},
          "req-llm-provider-rich-model"
        ),
        Event.openai_chat_terminal(
          "req-llm-provider-rich-model",
          :tool_calls,
          LLMProxy.Usage.new(5, 2)
        )
      ]
    end
  end

  setup do
    original_public_models = Application.get_env(:llm_proxy, :public_models)

    TestSupport.checkout_repo()
    Catalog.load([])
    Registry.register(Provider)
    ReqLLM.Providers.register(LLMProxy.Provider)

    on_exit(fn ->
      restore_public_models(original_public_models)
      Catalog.load([])
    end)

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

    assert [%Event{}, %Event{}, %Event{}] = Enum.to_list(stream)

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

  test "ReqLLM provider streams through LLMProxy without HTTP" do
    {:ok, _key, raw_key} = Storage.create_key("req-llm-stream-user")

    assert {:ok, response} =
             ReqLLM.Generation.stream_text(req_llm_model("req-llm-provider-model"), "hello",
               api_key: raw_key
             )

    assert ReqLLM.StreamResponse.text(response) == "hello stream"
    assert ReqLLM.StreamResponse.finish_reason(response) == :stop

    usage = ReqLLM.StreamResponse.usage(response)
    assert usage.input_tokens == 4
    assert usage.output_tokens == 3

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 4
    assert updated_key.output_tokens == 3
  end

  test "ReqLLM provider projects LLMProxy stream errors" do
    {:ok, _key, raw_key} = Storage.create_key("req-llm-error-user")

    assert {:ok, response} =
             ReqLLM.Generation.stream_text(req_llm_model("req-llm-provider-error-model"), "hello",
               api_key: raw_key
             )

    error =
      assert_raise ReqLLM.Error.API.Stream, fn ->
        Enum.to_list(response.stream)
      end

    assert error.cause == %{"message" => "stream failed", "status" => 502}
  end

  test "ReqLLM provider projects reasoning and tool calls" do
    {:ok, _key, raw_key} = Storage.create_key("req-llm-rich-stream-user")

    assert {:ok, response} =
             ReqLLM.Generation.stream_text(req_llm_model("req-llm-provider-rich-model"), "hello",
               api_key: raw_key
             )

    chunks = Enum.to_list(response.stream)

    assert Enum.any?(chunks, &match?(%ReqLLM.StreamChunk{type: :thinking, text: "thinking"}, &1))

    assert Enum.any?(chunks, fn
             %ReqLLM.StreamChunk{
               type: :tool_call,
               name: "lookup",
               arguments: %{"query" => "value"}
             } ->
               true

             _chunk ->
               false
           end)

    assert ReqLLM.StreamResponse.finish_reason(response) == :tool_calls
    assert ReqLLM.StreamResponse.usage(response).output_tokens == 2
  end

  test "ReqLLM stream cancellation releases the LLMProxy concurrency lease" do
    {:ok, key, raw_key} =
      Storage.create_key("req-llm-cancel-user", %{
        budget_limits: [Limit.concurrent_requests(1)]
      })

    :persistent_term.put({Provider, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({Provider, :test_pid}) end)

    assert {:ok, response} =
             ReqLLM.Generation.stream_text(
               req_llm_model("req-llm-provider-blocked-model"),
               "hello",
               api_key: raw_key
             )

    assert_receive :provider_waiting
    assert ConcurrencyLimiter.status(key).active == 1
    assert :ok = ReqLLM.StreamResponse.close(response)
    assert_eventually(fn -> ConcurrencyLimiter.status(key).active == 0 end)
  end

  test "ReqLLM provider encodes messages and tools as OpenAI wire data" do
    tool =
      ReqLLM.Tool.new!(
        name: "lookup",
        description: "Look up a value",
        parameter_schema: [query: [type: :string, required: true]],
        callback: fn _arguments -> {:ok, "found"} end
      )

    assert {:ok, %Request{body: body}} =
             LLMProxy.Provider.chat_request("hello",
               model: "req-llm-provider-model",
               tools: [tool]
             )

    assert %{
             "messages" => [%{"role" => "user", "content" => "hello"}],
             "tools" => [
               %{
                 "type" => "function",
                 "function" => %{"name" => "lookup", "parameters" => %{"type" => "object"}}
               }
             ]
           } = body

    assert {:ok, %Request{messages: [_message]}} = Request.parse(:openai_chat, body)
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

  test "calls an explicitly cataloged model alias" do
    Catalog.put_model(catalog_model("public-provider-alias"))
    {:ok, key, _raw_key} = Storage.create_key("catalog-provider-user")

    assert {:ok, response} =
             LLMProxy.chat("hello", model: "public-provider-alias", api_key: key)

    assert LLMProxy.Response.to_openai(response)["model"] == "req-llm-provider-model"
  end

  test "rejects a catalog model alias outside the public allowlist" do
    Catalog.put_model(catalog_model("public-provider-alias"))
    Application.put_env(:llm_proxy, :public_models, ["another-model"])
    {:ok, key, _raw_key} = Storage.create_key("restricted-catalog-provider-user")

    assert {:error, {:not_found, "Model 'public-provider-alias' not found"}} =
             LLMProxy.chat("hello", model: "public-provider-alias", api_key: key)
  end

  defp catalog_model(name) do
    Model.new!(
      name: name,
      deployments: [
        Deployment.new!(provider: Provider, upstream_model: "req-llm-provider-model")
      ]
    )
  end

  defp req_llm_model(id) do
    %{id: id, provider: :llm_proxy, model: id}
  end

  defp assert_eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)

      true ->
        flunk("condition did not become true")
    end
  end

  defp restore_public_models(nil), do: Application.delete_env(:llm_proxy, :public_models)

  defp restore_public_models(models),
    do: Application.put_env(:llm_proxy, :public_models, models)
end
