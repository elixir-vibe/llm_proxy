defmodule LLMProxy.ConfigTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Config
  alias LLMProxy.Providers.{Anthropic, OpenAI, OpenAICodex}

  setup do
    original_providers = Application.get_env(:llm_proxy, :providers)
    original_catalog = Application.get_env(:llm_proxy, :catalog)
    original_models = Application.get_env(:llm_proxy, :models)
    original_body_limit = Application.get_env(:llm_proxy, :body_limit_bytes)
    original_connect_timeout = Application.get_env(:llm_proxy, :provider_connect_timeout_ms)
    original_max_retries = Application.get_env(:llm_proxy, :max_retries)
    original_replay_policy = Application.get_env(:llm_proxy, :replay_policy)

    on_exit(fn ->
      restore_env(:providers, original_providers)
      restore_env(:catalog, original_catalog)
      restore_env(:models, original_models)
      restore_env(:body_limit_bytes, original_body_limit)
      restore_env(:provider_connect_timeout_ms, original_connect_timeout)
      restore_env(:max_retries, original_max_retries)
      restore_env(:replay_policy, original_replay_policy)
    end)

    :ok
  end

  test "configures the authenticated JSON body limit in bytes" do
    Application.put_env(:llm_proxy, :body_limit_bytes, 64_000_000)
    assert Config.body_limit_bytes() == 64_000_000

    Application.put_env(:llm_proxy, :body_limit_bytes, 0)

    assert_raise ArgumentError, ~r/:body_limit_bytes must be a positive integer/, fn ->
      Config.body_limit_bytes()
    end
  end

  test "configures a finite provider connection timeout" do
    Application.put_env(:llm_proxy, :provider_connect_timeout_ms, 12_000)
    assert Config.provider_connect_timeout_ms() == 12_000

    Application.put_env(:llm_proxy, :provider_connect_timeout_ms, :infinity)

    assert_raise ArgumentError, ~r/:provider_connect_timeout_ms must be a positive integer/, fn ->
      Config.provider_connect_timeout_ms()
    end
  end

  test "derives a finite attempt budget from max retries" do
    Application.put_env(:llm_proxy, :max_retries, 2)

    assert Config.max_retries() == 2
    assert Config.max_attempts() == 3

    Application.put_env(:llm_proxy, :max_retries, -1)

    assert_raise ArgumentError, ~r/:max_retries must be a non-negative integer/, fn ->
      Config.max_attempts()
    end
  end

  test "configures an explicit replay policy" do
    Application.put_env(:llm_proxy, :replay_policy, :allow_uncertain)
    assert Config.replay_policy() == :allow_uncertain

    Application.put_env(:llm_proxy, :replay_policy, :always)
    assert_raise ArgumentError, ~r/:replay_policy must be/, fn -> Config.replay_policy() end
  end

  test "configures bounded concurrent ReqLLM streaming pools" do
    assert ReqLLM.Application.get_finch_config()[:pools][:default] == [
             protocols: [:http1],
             size: 4,
             count: 8
           ]
  end

  test "normalizes readable provider config" do
    Application.put_env(:llm_proxy, :providers,
      openai_codex: [base_url: "https://chatgpt.example", oauth_tokens: "token"],
      kimi: [adapter: :openai, base_url: "https://kimi.example"],
      openrouter: [http_referer: "https://example.test"]
    )

    assert Config.provider_value("openai-codex", :base_url) == "https://chatgpt.example"
    assert Config.provider_value(:openai_codex, :oauth_tokens) == "token"
    assert Config.provider_value(:kimi, :adapter) == :openai
    assert Config.provider_value(:kimi, :base_url) == "https://kimi.example"
    assert Config.provider_value("openrouter", :http_referer) == "https://example.test"
  end

  test "normalizes readable models config into catalog deployments" do
    Application.put_env(:llm_proxy, :catalog, [])
    Application.put_env(:llm_proxy, :providers, kimi: [adapter: :openai, token_pool: "kimi-code"])

    Application.put_env(:llm_proxy, :models,
      codex: [
        routes: [[to: :openai_codex, model: "gpt-5.3-codex-spark"]]
      ],
      kimi: [routes: [[to: :kimi, model: "k3"]]],
      fast: [
        routing: :lowest_cost,
        routes: [
          [to: :openai, model: "gpt-4o-mini", timeout_ms: 15_000],
          [to: :anthropic, model: "claude-3-haiku-20240307", order: 2]
        ]
      ]
    )

    assert [codex, kimi, fast] = Config.catalog()

    assert codex.name == "codex"
    assert [%{provider: OpenAICodex, upstream_model: "gpt-5.3-codex-spark"}] = codex.deployments

    assert fast.name == "fast"
    assert fast.routing_strategy == :lowest_cost

    assert [
             %{provider: OpenAI, upstream_model: "gpt-4o-mini", timeout_ms: 15_000},
             %{provider: Anthropic, upstream_model: "claude-3-haiku-20240307", order: 2}
           ] = fast.deployments

    assert kimi.name == "kimi"

    assert [
             %{
               provider: LLMProxy.Providers.ReqLLM,
               provider_name: "kimi",
               upstream_model: "k3",
               token_pool: "kimi-code"
             }
           ] = kimi.deployments
  end

  test "catalog config accepts strict model structs" do
    Application.put_env(:llm_proxy, :models, [])

    model =
      Model.new!(
        name: "strict",
        deployments: [
          Deployment.new!(
            provider: OpenAICodex,
            upstream_model: "gpt-5.3-codex-spark"
          )
        ]
      )

    Application.put_env(:llm_proxy, :catalog, [model])

    assert [^model] = Config.catalog()
  end

  test "models config rejects invalid deployment values" do
    Application.put_env(:llm_proxy, :catalog, [])

    Application.put_env(:llm_proxy, :models,
      bad: [routes: [[to: :openai, model: "gpt-4o", weight: 0]]]
    )

    assert_raise ArgumentError, ~r/weight must be a positive integer/, fn ->
      Config.catalog()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:llm_proxy, key)
  defp restore_env(key, value), do: Application.put_env(:llm_proxy, key, value)
end
