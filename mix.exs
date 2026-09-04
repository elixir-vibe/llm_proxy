defmodule LLMProxy.MixProject do
  use Mix.Project

  @source_url "https://github.com/elixir-vibe/llm_proxy"
  @version "0.2.1"

  def project do
    [
      app: :llm_proxy,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      elixirc_options: [
        no_warn_undefined: [
          {Igniter, :add_notice, 2},
          {Igniter.Code.Common, :nodes_equal?, 2},
          {Igniter.Code.List, :replace_in_list, 3},
          {Igniter.Mix.Task.Info, :__struct__, 1},
          {Igniter.Project.TaskAliases, :add_alias, 4},
          {Igniter.Project.TaskAliases, :modify_existing_alias, 3}
        ]
      ],
      dialyzer: [plt_add_apps: [:mix]],
      test_coverage: [
        summary: [threshold: 85],
        ignore_modules: [
          LLMProxy.HTTP,
          LLMProxy.Providers.Anthropic,
          LLMProxy.Providers.Behaviour,
          LLMProxy.Providers.OpenAI,
          LLMProxy.Providers.OpenRouter
        ]
      ]
    ]
  end

  def cli do
    [preferred_envs: [ci: :test, integration: :test, e2e: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :req],
      mod: {LLMProxy.Application, []}
    ]
  end

  defp description do
    "Elixir-native LLM gateway for embedded and standalone deployments with provider " <>
      "routing, quotas, usage tracking, and OpenAI-compatible APIs."
  end

  defp package do
    [
      name: "llm_proxy",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv guides .formatter.exs mix.exs README.md CHANGELOG.md ROADMAP.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "ROADMAP.md",
        "guides/introduction/getting-started.md",
        "guides/introduction/library-mode.md",
        "guides/introduction/standalone-mode.md",
        "guides/features/providers-and-routing.md",
        "guides/features/governance-and-observability.md",
        "guides/features/cache-and-guardrails.md",
        "guides/features/admin-integration.md",
        "guides/deployment/standalone-deployment.md",
        "guides/reference/configuration.cheatmd",
        "guides/reference/http-api.cheatmd",
        "guides/internals/architecture.md"
      ],
      groups_for_extras: [
        Introduction: ~r/guides\/introduction\//,
        Features: ~r/guides\/features\//,
        Deployment: ~r/guides\/deployment\//,
        Reference: ~r/guides\/reference\//,
        Internals: ~r/guides\/internals\//
      ],
      groups_for_modules: [
        Core: [
          LLMProxy,
          LLMProxy.Actor,
          LLMProxy.Provider,
          LLMProxy.Response,
          LLMProxy.Usage
        ],
        "Provider Credentials": [
          LLMProxy.Provider.Credential,
          LLMProxy.Provider.TokenCodec,
          LLMProxy.Provider.TokenCodec.AESGCM,
          LLMProxy.Provider.TokenCodec.Migration,
          LLMProxy.Provider.TokenCodec.Plaintext
        ],
        "Catalog and Routing": [
          LLMProxy.Catalog,
          LLMProxy.Catalog.Model,
          LLMProxy.Catalog.Deployment,
          LLMProxy.Providers.Registry,
          LLMProxy.Providers.Execution
        ],
        Extensions: [
          LLMProxy.Cache,
          LLMProxy.Guardrail,
          LLMProxy.Storage,
          LLMProxy.Storage.Adapter
        ],
        "HTTP and Phoenix": [
          LLMProxy.Router,
          LLMProxy.HTTP.Router,
          LLMProxy.Phoenix.Router
        ],
        Operations: [
          LLMProxy.ConcurrencyLimiter,
          LLMProxy.Drain,
          LLMProxy.Ops,
          LLMProxy.ReleaseTasks,
          LLMProxy.Telemetry
        ]
      ]
    ]
  end

  defp deps do
    [
      {:release_kit, "~> 0.3.0", runtime: false},
      {:igniter, "~> 0.8", optional: true},
      {:phoenix, "~> 1.8", optional: true},
      {:plug_cowboy, "~> 2.7"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.17", optional: true},
      {:quackdb, "~> 0.5.20"},
      {:req_llm, "~> 1.22"},
      {:req, "~> 0.7"},
      {:llm_db, "~> 2026.9", runtime: false},
      {:dotenvy, "~> 1.1"},
      {:toml, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:json_codec, "~> 0.2.3"},
      {:incant, "~> 0.1", optional: true},
      {:safe_rpc, "~> 0.1.17"},

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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
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
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      integration: ["test --only integration"],
      e2e: ["test --only e2e"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells --strict"
      ]
    ]
  end
end
