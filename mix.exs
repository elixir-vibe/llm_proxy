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
      preferred_cli_env: [ci: :test],
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LLMProxy.Application, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:ecto_sqlite3, "~> 0.17"},
      {:req_llm, "~> 1.6"},
      {:dotenvy, "~> 1.1"},
      {:jason, "~> 1.4"},

      # Dev/test
      {:mox, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      ci: [
        "compile --warnings-as-errors",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna"
      ]
    ]
  end
end
