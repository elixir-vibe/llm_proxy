import Config

config :llm_proxy, LLMProxy.Repo, database: "llm_proxy_dev.db"

config :llm_proxy, LLMProxy.Web.Endpoint,
  http: [port: 4000],
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-development!!!",
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  server: true,
  watchers: []

config :volt, :server,
  prefix: "/assets",
  watch_dirs: ["lib/", "assets/"]

config :logger, level: :debug
