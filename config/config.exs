import Config

config :llm_proxy, ecto_repos: [LLMProxy.Repo]

config :llm_proxy, LLMProxy.Repo,
  database: "llm_proxy_#{config_env()}.db"

config :llm_proxy, LLMProxyWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: LLMProxyWeb.ErrorHTML], layout: false],
  pubsub_server: LLMProxy.PubSub,
  live_view: [signing_salt: "llm_proxy_lv"]

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

import_config "#{config_env()}.exs"
