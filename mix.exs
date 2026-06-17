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
          LLMProxy.Providers.OpenRouter,
          LLMProxy.Web.Layouts,
          LLMProxy.Web.Router.Helpers
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
      {:phoenix, "~> 1.8", optional: true},
      {:phoenix_html, "~> 4.3", optional: true},
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:plug_cowboy, "~> 2.7", optional: true},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.17", optional: true},
      {:req_llm, "~> 1.6"},
      {:llm_db, "~> 2026.3"},
      {:dotenvy, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:volt, "~> 0.14", optional: true},
      {:incant, git: "git@github.com:elixir-vibe/incant.git", branch: "main"},
      {:safe_rpc, git: "git@github.com:elixir-vibe/safe_rpc.git", branch: "master"},

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
        applications: [llm_proxy: :permanent]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "fetch_models", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.build": ["volt.build --tailwind"],
      "assets.deploy": ["volt.build --tailwind", "phx.digest"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "volt.js.check",
        "assets.build",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
