defmodule LLMProxy.ProviderCatalogTest do
  use ExUnit.Case

  alias LLMProxy.Catalog
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  defmodule Provider do
    def name, do: "provider-catalog-test"
    def models, do: ["upstream-catalog-model"]

    def call(%{"model" => "upstream-catalog-model"}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "catalog-response",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "via catalog"},
               "finish_reason" => "stop"
             }
           ],
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
    original_public_models = Application.get_env(:llm_proxy, :public_models)
    TestSupport.checkout_repo()
    Catalog.load([])
    Registry.register(Provider)

    Catalog.put_model(
      Model.new!(
        name: "public-catalog-model",
        deployments: [
          Deployment.new!(provider: Provider, upstream_model: "upstream-catalog-model")
        ]
      )
    )

    on_exit(fn ->
      Catalog.load([])

      if original_public_models == nil do
        Application.delete_env(:llm_proxy, :public_models)
      else
        Application.put_env(:llm_proxy, :public_models, original_public_models)
      end
    end)

    :ok
  end

  test "LLMProxy.Provider resolves public catalog model names to upstream deployments" do
    {:ok, key, _raw_key} = Storage.create_key("catalog-user")

    assert {:ok, response} =
             LLMProxy.chat("hello", model: "public-catalog-model", api_key: key)

    assert LLMProxy.Response.to_openai(response)["model"] == "upstream-catalog-model"
    assert response.usage.input_tokens == 2
    assert response.usage.output_tokens == 3
  end

  test "LLMProxy.Provider rejects a model outside the public allowlist" do
    {:ok, key, _raw_key} = Storage.create_key("catalog-user")
    Application.put_env(:llm_proxy, :public_models, ["another-model"])

    assert {:error, {:not_found, "Model 'public-catalog-model' not found"}} =
             LLMProxy.chat("hello", model: "public-catalog-model", api_key: key)
  end
end
