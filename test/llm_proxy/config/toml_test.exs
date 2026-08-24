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

  test "decodes standalone routing policy" do
    input = """
    [routing]
    max_retries = 2
    replay_policy = "allow_uncertain"
    """

    assert {:ok, [max_retries: 2, replay_policy: :allow_uncertain]} = TOML.decode(input)
  end

  test "decodes provider-token rollout policy" do
    input = """
    [provider_tokens]
    allow_plaintext = false
    """

    assert {:ok, [provider_token_allow_plaintext: false]} = TOML.decode(input)

    assert_raise ArgumentError, ~r/provider_tokens.allow_plaintext must be a boolean/, fn ->
      TOML.decode(~s([provider_tokens]\nallow_plaintext = "false"))
    end

    assert_raise ArgumentError, ~r/provider_tokens only supports allow_plaintext/, fn ->
      TOML.decode(~s([provider_tokens]\nkeys = "must-not-live-in-toml"))
    end
  end

  test "rejects invalid standalone routing policy" do
    assert_raise ArgumentError, ~r/routing.max_retries must be a non-negative integer/, fn ->
      TOML.decode("[routing]\nmax_retries = -1")
    end

    assert_raise ArgumentError,
                 ~r/routing.replay_policy must be safe_only or allow_uncertain/,
                 fn ->
                   TOML.decode(~s([routing]\nreplay_policy = "always"))
                 end
  end

  test "returns TOML parser errors" do
    assert {:error, {:invalid_toml, _reason}} = TOML.decode("[invalid]\na = 1 b = 2")
  end
end
