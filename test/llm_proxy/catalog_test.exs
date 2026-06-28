defmodule LLMProxy.CatalogTest do
  use ExUnit.Case

  alias LLMProxy.Catalog
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.{Anthropic, OpenAI, Registry}
  alias LLMProxy.Providers.Routing.{Attempt, RoundRobin}

  defmodule Provider do
    def name, do: "catalog-provider"
    def models, do: ["primary", "upstream-model", "second-upstream-model"]
  end

  setup do
    Catalog.load([])
    RoundRobin.reset()
    Registry.register(Provider)

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :fallbacks)
      Application.delete_env(:llm_proxy, :max_retries)
      Catalog.load([])
      RoundRobin.reset()
    end)

    :ok
  end

  test "loads catalog models" do
    Catalog.load([
      model("fast", [deployment(Provider, "upstream-model", order: 2)])
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
    Catalog.put_model(model("fast", [deployment(Provider, "upstream-model")]))

    assert {:ok, {Provider, "upstream-model"}} = Registry.resolve_model("fast")

    assert {:ok, [%Attempt{provider: Provider, model: "upstream-model"}]} =
             Registry.resolve_attempts("fast")

    assert Provider == Registry.get_provider("fast")
  end

  test "catalog deployments are ordered by strategy" do
    Catalog.put_model(
      model("ordered", [
        deployment(Provider, "second-upstream-model", order: 2),
        deployment(Provider, "upstream-model", order: 1)
      ])
    )

    assert {:ok,
            [
              %Attempt{provider: Provider, model: "upstream-model"},
              %Attempt{provider: Provider, model: "second-upstream-model"}
            ]} = Registry.resolve_attempts("ordered")
  end

  test "round robin strategy rotates deployments within order groups" do
    Catalog.put_model(
      model(
        "round-robin",
        [deployment(Provider, "upstream-model"), deployment(Provider, "second-upstream-model")],
        routing_strategy: :round_robin
      )
    )

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
    Catalog.put_model(
      model(
        "weighted",
        [
          deployment(Provider, "second-upstream-model", order: 2, weight: 10),
          deployment(Provider, "upstream-model", order: 1, weight: 1)
        ],
        routing_strategy: :weighted_shuffle
      )
    )

    assert {:ok,
            [
              %Attempt{provider: Provider, model: "upstream-model"},
              %Attempt{provider: Provider, model: "second-upstream-model"}
            ]} = Registry.resolve_attempts("weighted")
  end

  test "lowest cost strategy orders deployments by LLMDB pricing" do
    Catalog.put_model(
      model(
        "cheap",
        [deployment(OpenAI, "gpt-4o"), deployment(Anthropic, "claude-3-haiku-20240307")],
        routing_strategy: :lowest_cost
      )
    )

    assert {:ok,
            [
              %Attempt{provider: Anthropic, model: "claude-3-haiku-20240307"},
              %Attempt{provider: OpenAI, model: "gpt-4o"}
            ]} = Registry.resolve_attempts("cheap")
  end

  test "registry applies max_retries to configured fallback attempts" do
    Application.put_env(:llm_proxy, :fallbacks, %{
      "primary" => ["upstream-model", "second-upstream-model"]
    })

    Application.put_env(:llm_proxy, :max_retries, 1)

    assert {:ok,
            [
              %Attempt{provider: Provider, model: "primary"},
              %Attempt{provider: Provider, model: "upstream-model"}
            ]} = Registry.resolve_attempts("primary")
  end

  test "all models includes visible aliases and hides hidden aliases" do
    Catalog.load([
      model("visible", [deployment(Provider, "upstream-model")]),
      model("hidden", [deployment(Provider, "upstream-model")], hidden: true)
    ])

    ids = Registry.all_models() |> Enum.map(& &1.id)

    assert "visible" in ids
    refute "hidden" in ids
    assert "upstream-model" in ids
  end

  defp model(name, deployments, opts \\ []) do
    Model.new!(Keyword.merge([name: name, deployments: deployments], opts))
  end

  defp deployment(provider, upstream_model, opts \\ []) do
    Deployment.new!(Keyword.merge([provider: provider, upstream_model: upstream_model], opts))
  end
end
