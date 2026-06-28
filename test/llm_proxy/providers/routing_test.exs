defmodule LLMProxy.Providers.RoutingTest do
  use ExUnit.Case

  alias LLMProxy.Catalog
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  defmodule Provider do
    def name, do: "provider-routing-test"
    def models, do: ["primary-routing-model", "secondary-routing-model"]

    def call(%{"model" => "primary-routing-model"}, _user_id),
      do: {:error, Result.error("primary failed", 500, nil)}

    def call(%{"model" => "secondary-routing-model"}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "routing-response",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "routed"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
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
    Catalog.load([])
    Registry.register(Provider)

    Catalog.put_model(
      Model.new!(
        name: "routed-model",
        deployments: [
          Deployment.new!(provider: Provider, upstream_model: "primary-routing-model", order: 1),
          Deployment.new!(provider: Provider, upstream_model: "secondary-routing-model", order: 2)
        ]
      )
    )

    on_exit(fn -> Catalog.load([]) end)

    :ok
  end

  test "LLMProxy.Provider tries ordered catalog deployments" do
    {:ok, key, _raw_key} = Storage.create_key("routing-user")

    assert {:ok, response} = LLMProxy.chat("hello", model: "routed-model", api_key: key)
    assert response.body["model"] == "secondary-routing-model"
    assert response.usage.input_tokens == 1
    assert response.usage.output_tokens == 2
  end
end
