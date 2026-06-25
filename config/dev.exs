import Config

config :llm_proxy, LLMProxy.Repo, database: "llm_proxy_dev.db"

config :llm_proxy,
  http: [port: 4000]

config :logger, level: :debug
