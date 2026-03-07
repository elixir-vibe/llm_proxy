import Config

if config_env() == :prod do
  config :llm_proxy, LLMProxy.Repo,
    database: System.get_env("DATABASE_PATH", "./llm_proxy.db")

  config :llm_proxy,
    port: String.to_integer(System.get_env("PORT", "4000")),
    master_key: System.get_env("MASTER_KEY"),
    public_url: System.get_env("PUBLIC_URL", ""),
    exa_api_key: System.get_env("EXA_API_KEY", ""),
    context7_api_key: System.get_env("CONTEXT7_API_KEY", ""),
    openrouter_api_keys: System.get_env("OPENROUTER_API_KEYS", ""),
    openai_api_keys: System.get_env("OPENAI_API_KEYS", "")
end
