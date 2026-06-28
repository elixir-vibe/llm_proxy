defmodule LLMProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :llm_proxy,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      dialyzer: [plt_add_apps: [:mix]],
      test_coverage: [
        summary: [threshold: 85],
        ignore_modules: [
          Mix.Tasks.FetchModels,
          LLMProxy.CacheBodyReader,
          LLMProxy.HTTP,
          LLMProxy.Repo,
          LLMProxy.Routes.Moderations,
          LLMProxy.Routes.Setup,
          LLMProxy.Providers.Anthropic,
          LLMProxy.Providers.Behaviour,
          LLMProxy.Providers.Helpers,
          LLMProxy.Providers.OpenAI,
          LLMProxy.Providers.OpenRouter
        ]
      ]
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LLMProxy.Application, []}
    ]
  end

  defp deps do
    [
      {:release_kit, "~> 0.3.0", runtime: false},
      {:phoenix, "~> 1.8", optional: true},
      {:plug_cowboy, "~> 2.7"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.17", optional: true},
      {:quackdb, "~> 0.5.14"},
      # Temporary fork until ReqLLM PR #791 is merged/released. LLMProxy relies on
      # these encoder fixes to avoid local OpenAI/Anthropic wire-format patches.
      {:req_llm,
       git: "https://github.com/dannote/req_llm.git", branch: "fix/provider-context-encoding"},
      {:llm_db, "~> 2026.3", runtime: false},
      {:dotenvy, "~> 1.1"},
      {:toml, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:incant, git: "git@github.com:elixir-vibe/incant.git", branch: "main"},
      {:safe_rpc, "~> 0.1.12"},

      # OpenTelemetry
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry_cowboy, "~> 1.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_req, "~> 1.0"},

      # Dev/test
      {:mox, "~> 1.1", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      llm_proxy: [
        applications: [llm_proxy: :permanent],
        config_providers: [{LLMProxy.Config.Provider, []}]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "fetch_models", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
