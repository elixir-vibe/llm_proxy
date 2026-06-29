defmodule LLMProxy.ConfigTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Config
  alias LLMProxy.Providers.{Anthropic, OpenAI, OpenAICodex}

  setup do
    original_providers = Application.get_env(:llm_proxy, :providers)
    original_catalog = Application.get_env(:llm_proxy, :catalog)
    original_models = Application.get_env(:llm_proxy, :models)

    on_exit(fn ->
      restore_env(:providers, original_providers)
      restore_env(:catalog, original_catalog)
      restore_env(:models, original_models)
    end)

    :ok
  end

  test "normalizes readable provider config" do
    Application.put_env(:llm_proxy, :providers,
      openai_codex: [base_url: "https://chatgpt.example", oauth_tokens: "token"],
      openrouter: [http_referer: "https://example.test"]
    )

    assert Config.provider_value("openai-codex", :base_url) == "https://chatgpt.example"
    assert Config.provider_value(:openai_codex, :oauth_tokens) == "token"
    assert Config.provider_value("openrouter", :http_referer) == "https://example.test"
  end

  test "normalizes readable models config into catalog deployments" do
    Application.put_env(:llm_proxy, :catalog, [])

    Application.put_env(:llm_proxy, :models,
      codex: [
        routes: [[to: :openai_codex, model: "gpt-5.3-codex-spark"]]
      ],
      fast: [
        routing: :lowest_cost,
        routes: [
          [to: :openai, model: "gpt-4o-mini", timeout_ms: 15_000],
          [to: :anthropic, model: "claude-3-haiku-20240307", order: 2]
        ]
      ]
    )

    assert [codex, fast] = Config.catalog()

    assert codex.name == "codex"
    assert [%{provider: OpenAICodex, upstream_model: "gpt-5.3-codex-spark"}] = codex.deployments

    assert fast.name == "fast"
    assert fast.routing_strategy == :lowest_cost

    assert [
             %{provider: OpenAI, upstream_model: "gpt-4o-mini", timeout_ms: 15_000},
             %{provider: Anthropic, upstream_model: "claude-3-haiku-20240307", order: 2}
           ] = fast.deployments
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
