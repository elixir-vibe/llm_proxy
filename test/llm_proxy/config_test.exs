defmodule LLMProxy.ConfigTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Config
  alias LLMProxy.Providers.{Anthropic, OpenAICodex, OpenAI}

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
        route: [to: :openai_codex, model: "gpt-5.3-codex-spark"]
      ],
      fast: [
        routing: :lowest_cost,
        routes: [
          [to: :openai, model: "gpt-4o-mini", timeout: 15_000],
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

  test "keeps existing catalog config compatible" do
    Application.put_env(:llm_proxy, :models, [])

    Application.put_env(:llm_proxy, :catalog, [
      %{
        "name" => "legacy",
        "deployments" => [
          %{"provider" => "openai-codex", "upstream_model" => "gpt-5.3-codex-spark"}
        ]
      }
    ])

    assert [%{name: "legacy", deployments: [%{provider: OpenAICodex}]}] = Config.catalog()
  end

  defp restore_env(key, nil), do: Application.delete_env(:llm_proxy, key)
  defp restore_env(key, value), do: Application.put_env(:llm_proxy, key, value)
end
