defmodule LLMProxy.RemoteTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Remote
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  defmodule Provider do
    def name, do: "remote-provider-test"
    def models, do: ["remote-provider-model"]

    def call(%{"model" => "remote-provider-model", "messages" => _messages}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "remote-provider-test-1",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "hello from remote"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 4}
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
    ReqLLM.Providers.register(LLMProxy.ReqLLM.RemoteProvider)
    :ok
  end

  test "Remote.chat calls Provider through erpc" do
    {:ok, key, _raw_key} = Storage.create_key("remote-user")

    assert {:ok, response} =
             Remote.chat(node(), "hello", model: "remote-provider-model", api_key: key)

    assert response.body["model"] == "remote-provider-model"
    assert response.usage.input_tokens == 5
    assert is_binary(response.trace_id)
  end

  test "ReqLLM remote provider delegates through Remote" do
    {:ok, _key, raw_key} = Storage.create_key("remote-req-llm-user")

    model = %{
      id: "remote-provider-model",
      provider: :llm_proxy_remote,
      model: "remote-provider-model"
    }

    assert {:ok, response} =
             ReqLLM.Generation.generate_text(model, "hello", node: node(), api_key: raw_key)

    assert ReqLLM.Response.text(response) == "hello from remote"
    assert response.provider_meta.trace_id
    assert response.usage.input_tokens == 5
  end
end
