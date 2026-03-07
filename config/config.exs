import Config

config :llm_proxy, ecto_repos: [LLMProxy.Repo]

config :llm_proxy, LLMProxy.Repo,
  database: "llm_proxy_#{config_env()}.db"

import_config "#{config_env()}.exs"
