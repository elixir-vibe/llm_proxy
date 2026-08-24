defmodule LLMProxy.Config.TOMLTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Config.TOML

  test "decodes providers and models into application config" do
    input = """
    [providers.openai-codex]
    base_url = "https://chatgpt.com/backend-api"
    oauth_tokens = "token"

    [providers.configured]
    adapter = "openai"
    base_url = "https://configured.example/v1"
    token_pool = "configured-production"

    [providers.anthropic.conversion_defaults]
    max_tokens = 4096

    [[models]]
    name = "codex"

    [[models.routes]]
    to = "openai-codex"
    model = "gpt-5.3-codex-spark"
    timeout = 15000

    [[models]]
    name = "fast"
    routing = "lowest_cost"

    [[models.routes]]
    to = "openai"
    model = "gpt-4o-mini"
    order = 1
    """

    assert {:ok,
            [
              providers: %{
                "openai-codex" => %{
                  base_url: "https://chatgpt.com/backend-api",
                  oauth_tokens: "token"
                },
                "anthropic" => %{conversion_defaults: %{max_tokens: 4096}},
                "configured" => %{
                  adapter: "openai",
                  base_url: "https://configured.example/v1",
                  token_pool: "configured-production"
                }
              },
              models: [
                %{
                  name: "codex",
                  routes: [
                    %{to: "openai-codex", model: "gpt-5.3-codex-spark", timeout_ms: 15_000}
                  ]
                },
                %{
                  name: "fast",
                  routing: :lowest_cost,
                  routes: [%{to: "openai", model: "gpt-4o-mini", order: 1}]
                }
              ]
            ]} = TOML.decode(input)
  end

  test "decodes latency-aware routing" do
    input = """
    [[models]]
    name = "fastest"
    routing = "latency_aware"

    [[models.routes]]
    to = "openrouter"
    model = "upstream-model"
    """

    assert {:ok,
            [
              models: [
                %{
                  name: "fastest",
                  routing: :latency_aware,
                  routes: [%{to: "openrouter", model: "upstream-model"}]
                }
              ]
            ]} = TOML.decode(input)
  end

  test "supports catalog.models as an alternate TOML nesting" do
    input = """
    [[catalog.models]]
    name = "codex"

    [[catalog.models.routes]]
    to = "openai-codex"
    model = "gpt-5.3-codex-spark"
    """

    assert {:ok, [models: [%{name: "codex", routes: [%{to: "openai-codex"}]}]]} =
             TOML.decode(input)
  end

  test "returns TOML parser errors" do
    assert {:error, {:invalid_toml, _reason}} = TOML.decode("[invalid]\na = 1 b = 2")
  end
end
