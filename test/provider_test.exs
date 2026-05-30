defmodule LLMProxy.ProviderTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
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

    assert response.body["model"] == "req-llm-provider-model"
    assert response.usage.input_tokens == 4
    assert response.usage.output_tokens == 3

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
