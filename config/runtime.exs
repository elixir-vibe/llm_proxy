import Config
import Dotenvy

if config_env() in [:dev, :prod] do
  ".env"
  |> source!()
  |> Map.merge(System.get_env())
  |> System.put_env()
end

if config_env() == :prod do
  config :llm_proxy, LLMProxy.Repo, database: System.get_env("DATABASE_PATH", "./llm_proxy.db")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  config :llm_proxy, LLMProxy.Web.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: secret_key_base,
    server: true
end

if config_env() in [:dev, :prod] do
  fallbacks =
    case System.get_env("LLM_FALLBACKS") do
      nil -> %{}
      json -> Jason.decode!(json)
    end

  config :llm_proxy,
    master_key: System.get_env("MASTER_KEY"),
    public_url: System.get_env("PUBLIC_URL", ""),
    openrouter_api_keys: System.get_env("OPENROUTER_API_KEYS", ""),
    openai_api_keys: System.get_env("OPENAI_API_KEYS", ""),
    anthropic_api_keys: System.get_env("ANTHROPIC_API_KEYS", ""),
    fallbacks: fallbacks,
    max_retries: String.to_integer(System.get_env("LLM_MAX_RETRIES", "1"))
end
