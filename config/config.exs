import Config

config :llm_proxy,
  ecto_repos: [LLMProxy.Repo],
  repo: LLMProxy.Repo

config :llm_proxy, LLMProxy.Repo, database: "llm_proxy_#{config_env()}.db"

config :llm_proxy,
  http: [port: 4000]

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

config :release_kit, :artifact,
  port: 4100,
  health_path: "/health",
  env_clear: %{
    "DATABASE_PATH" => "/var/lib/toys/llm-proxy/main.db",
    "PORT" => "4100",
    "PUBLIC_URL" => "https://llm.elixir.toys",
    "RELEASE_DISTRIBUTION" => "none"
  },
  env_secret: [
    "MASTER_KEY",
    "ANTHROPIC_API_KEYS",
    "OPENAI_API_KEYS",
    "OPENROUTER_API_KEYS"
  ]

import_config "#{config_env()}.exs"
