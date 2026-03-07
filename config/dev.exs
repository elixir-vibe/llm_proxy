import Config

config :llm_proxy, LlmProxy.Repo,
  database: "llm_proxy_dev.db"

config :logger, level: :debug
