import Config

config :llm_proxy,
  ecto_repos: [LLMProxy.Repo],
  repo: LLMProxy.Repo

config :llm_proxy, LLMProxy.Repo, database: "llm_proxy_#{config_env()}.db"

config :llm_proxy, LLMProxy.Web.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: LLMProxy.Web.ErrorHTML], layout: false],
  pubsub_server: LLMProxy.PubSub,
  live_view: [signing_salt: "llm_proxy_lv"]

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

config :volt,
  entry: "assets/js/app.ts",
  outdir: "priv/static/assets",
  root: "assets",
  sources: ["**/*.{js,ts}"],
  target: :es2020,
  minify: config_env() == :prod,
  sourcemap: :hidden,
  tailwind: [
    css: "assets/css/app.css",
    sources: [
      %{base: "lib/", pattern: "**/*.{ex,heex}"},
      %{base: "assets/", pattern: "**/*.{js,ts}"}
    ]
  ]

config :volt, :format,
  semi: false,
  single_quote: true

import_config "#{config_env()}.exs"
