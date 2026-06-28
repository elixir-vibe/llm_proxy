import Config

config :llm_proxy, LLMProxy.Storage.Repo.SQLite,
  database: "llm_proxy_dev.db",
  priv: "priv/repo"

config :llm_proxy,
  http: [port: 4000]

config :logger, level: :debug
