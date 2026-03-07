import Config

config :llm_proxy, ecto_repos: [LlmProxy.Repo]

config :llm_proxy, LlmProxy.Repo,
  database: "llm_proxy_#{config_env()}.db"

import_config "#{config_env()}.exs"
