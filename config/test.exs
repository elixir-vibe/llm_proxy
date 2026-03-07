import Config

config :llm_proxy, LLMProxy.Repo,
  database: "llm_proxy_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :logger, level: :warning
