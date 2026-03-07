import Config

config :llm_proxy, LLMProxy.Repo,
  database: "llm_proxy_dev.db"

config :logger, level: :debug
