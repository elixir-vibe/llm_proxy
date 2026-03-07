import Config

config :llm_proxy, LLMProxy.Repo,
  database: "llm_proxy_dev.db"

config :llm_proxy, LLMProxyWeb.Endpoint,
  http: [port: 4000],
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-development!!!",
  check_origin: false,
  debug_errors: true,
  server: true

config :logger, level: :debug
