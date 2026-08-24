defmodule LLMProxy.Providers.RegistryTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Catalog
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.Registry

  defmodule Provider do
    def name, do: "registry-public-model-test"
    def models, do: ["direct-model"]
  end

  setup do
    original_public_models = Application.get_env(:llm_proxy, :public_models)

    Catalog.load([
      model("public-a"),
      model("public-b"),
      model("hidden", hidden: true)
    ])

    Registry.register(Provider)

    on_exit(fn ->
      restore_public_models(original_public_models)
      Catalog.load([])
    end)

    :ok
  end

  test "uses all registered models when no public allowlist is configured" do
    Application.delete_env(:llm_proxy, :public_models)
    ids = Registry.public_models() |> Enum.map(& &1.id)

    assert "public-a" in ids
    assert "public-b" in ids
    assert "direct-model" in ids
    assert Registry.public_model?("direct-model")
  end

  test "a public allowlist exposes only visible catalog aliases in configured order" do
    Application.put_env(:llm_proxy, :public_models, [
      "public-b",
      "direct-model",
      "hidden",
      "public-a",
      "public-b"
    ])

    assert Enum.map(Registry.public_models(), & &1.id) == ["public-b", "public-a"]
    assert Registry.public_model?("public-b")
    refute Registry.public_model?("direct-model")
    refute Registry.public_model?("hidden")
    refute Registry.public_model?("unknown")
  end

  test "an explicit empty allowlist exposes no models" do
    Application.put_env(:llm_proxy, :public_models, [])

    assert Registry.public_models() == []
    refute Registry.public_model?("public-a")
  end

  defp model(name, opts \\ []) do
    Model.new!(
      Keyword.merge(
        [
          name: name,
          deployments: [Deployment.new!(provider: Provider, upstream_model: "direct-model")]
        ],
        opts
      )
    )
  end

  defp restore_public_models(nil), do: Application.delete_env(:llm_proxy, :public_models)

  defp restore_public_models(models),
    do: Application.put_env(:llm_proxy, :public_models, models)
end
