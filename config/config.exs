import Config

config :llm_proxy,
  ecto_repos: [LLMProxy.Storage.Repo.SQLite],
  repo: LLMProxy.Storage.Repo.SQLite

config :llm_proxy, LLMProxy.Storage.Repo.SQLite,
  database: "llm_proxy_#{config_env()}.db",
  priv: "priv/repo"

config :llm_proxy,
  http: [port: 4000]

# ReqLLM defaults to one HTTP/1 connection per Finch shard. Give each shard
# bounded parallel capacity so concurrent streaming requests do not queue behind
# a single long-lived upstream response.
config :req_llm,
  stream_pool_protocols: [:http1],
  stream_pool_size: 4,
  stream_pool_count: 8

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :none

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf

config :release_kit, :artifact,
  port: 4101,
  health_path: "/health",
  env_clear: %{
    "DATABASE_PATH" => "/var/lib/toys/llm-proxy/main.duckdb",
    "PORT" => "4101",
    "PUBLIC_URL" => "https://llm.elixir.toys",
    "LLM_PROXY_BODY_LIMIT_BYTES" => "32000000",
    "LLM_PROXY_RPC_SOCKET" => "/run/toys/llm-proxy/rpc.sock",
    "QUACKDB_BINARY_CACHE_DIR" => "/var/lib/toys/llm-proxy/duckdb-bin",
    "QUACKDB_ENDPOINT" => "quack:localhost:9494",
    "QUACKDB_URI" => "http://127.0.0.1:9494",
    "RELEASE_DISTRIBUTION" => "none"
  },
  env_secret: [
    "MASTER_KEY",
    "ANTHROPIC_API_KEYS",
    "LLM_PROXY_PROVIDER_KEYS",
    "OPENAI_API_KEYS",
    "OPENAI_CODEX_TOKENS",
    "OPENROUTER_API_KEYS"
  ]

import_config "#{config_env()}.exs"
