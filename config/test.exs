import Config

config :llm_proxy, LlmProxy.Repo,
  database: "llm_proxy_test.db",
  pool_size: 1

config :logger, level: :warning
