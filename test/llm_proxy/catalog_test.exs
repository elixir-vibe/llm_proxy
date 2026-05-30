defmodule LLMProxy.CatalogTest do
  use ExUnit.Case

  alias LLMProxy.Catalog
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.{Anthropic, OpenAI, Registry}
  alias LLMProxy.Routing.{Attempt, RoundRobin}

  defmodule Provider do
    def name, do: "catalog-provider"
    def models, do: ["upstream-model", "second-upstream-model"]
  end

  setup do
    Catalog.load([])
    RoundRobin.reset()
    Registry.register(Provider)

    on_exit(fn ->
      Catalog.load([])
      RoundRobin.reset()
    end)

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

    assert {:ok, [%Attempt{provider: Provider, model: "upstream-model"}]} =
             Registry.resolve_attempts("fast")

    assert Provider == Registry.get_provider("fast")
  end

  test "catalog deployments are ordered by strategy" do
    Catalog.put_model(%{
      name: "ordered",
      deployments: [
        %{provider: Provider, upstream_model: "second-upstream-model", order: 2},
        %{provider: Provider, upstream_model: "upstream-model", order: 1}
      ]
    })

    assert {:ok,
            [
              %Attempt{provider: Provider, model: "upstream-model"},
              %Attempt{provider: Provider, model: "second-upstream-model"}
            ]} = Registry.resolve_attempts("ordered")
  end

  test "round robin strategy rotates deployments within order groups" do
    Catalog.put_model(%{
      name: "round-robin",
      routing_strategy: :round_robin,
      deployments: [
        %{provider: Provider, upstream_model: "upstream-model"},
        %{provider: Provider, upstream_model: "second-upstream-model"}
      ]
    })

    assert {:ok,
            [
              %Attempt{provider: Provider, model: "upstream-model"},
              %Attempt{provider: Provider, model: "second-upstream-model"}
            ]} = Registry.resolve_attempts("round-robin")

    assert {:ok,
            [
              %Attempt{provider: Provider, model: "second-upstream-model"},
              %Attempt{provider: Provider, model: "upstream-model"}
            ]} = Registry.resolve_attempts("round-robin")
  end

  test "weighted shuffle keeps order groups and all deployments" do
    Catalog.put_model(%{
      name: "weighted",
      routing_strategy: "weighted_shuffle",
      deployments: [
        %{provider: Provider, upstream_model: "second-upstream-model", order: 2, weight: 10},
        %{provider: Provider, upstream_model: "upstream-model", order: 1, weight: 1}
      ]
    })

    assert {:ok,
            [
              %Attempt{provider: Provider, model: "upstream-model"},
              %Attempt{provider: Provider, model: "second-upstream-model"}
            ]} = Registry.resolve_attempts("weighted")
  end

  test "lowest cost strategy orders deployments by LLMDB pricing" do
    Catalog.put_model(%{
      name: "cheap",
      routing_strategy: :lowest_cost,
      deployments: [
        %{provider: OpenAI, upstream_model: "gpt-4o"},
        %{provider: Anthropic, upstream_model: "claude-3-haiku-20240307"}
      ]
    })

    assert {:ok,
            [
              %Attempt{provider: Anthropic, model: "claude-3-haiku-20240307"},
              %Attempt{provider: OpenAI, model: "gpt-4o"}
            ]} = Registry.resolve_attempts("cheap")
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
