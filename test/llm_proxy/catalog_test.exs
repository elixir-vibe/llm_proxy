defmodule LLMProxy.CatalogTest do
  use ExUnit.Case

  alias LLMProxy.Catalog
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.Registry

  defmodule Provider do
    def name, do: "catalog-provider"
    def models, do: ["upstream-model"]
  end

  setup do
    Catalog.load([])
    Registry.register(Provider)

    on_exit(fn -> Catalog.load([]) end)

    :ok
  end

  test "loads catalog models from maps" do
    Catalog.load([
      %{
        "name" => "fast",
        "deployments" => [
          %{"provider" => Provider, "upstream_model" => "upstream-model", "order" => 2}
        ]
      }
    ])

    assert %Model{
             name: "fast",
             deployments: [
               %Deployment{provider: Provider, upstream_model: "upstream-model", order: 2}
             ]
           } =
             Catalog.get_model("fast")
  end

  test "provider registry resolves catalog aliases to upstream deployments" do
    Catalog.put_model(%{
      name: "fast",
      deployments: [%{provider: Provider, upstream_model: "upstream-model"}]
    })

    assert {:ok, {Provider, "upstream-model"}} = Registry.resolve_model("fast")
    assert Provider == Registry.get_provider("fast")
  end

  test "all models includes visible aliases and hides hidden aliases" do
    Catalog.load([
      %{name: "visible", deployments: [%{provider: Provider, upstream_model: "upstream-model"}]},
      %{
        name: "hidden",
        hidden: true,
        deployments: [%{provider: Provider, upstream_model: "upstream-model"}]
      }
    ])

    ids = Registry.all_models() |> Enum.map(& &1.id)

    assert "visible" in ids
    refute "hidden" in ids
    assert "upstream-model" in ids
  end
end
