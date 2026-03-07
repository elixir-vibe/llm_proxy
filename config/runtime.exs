import Config

if config_env() in [:dev, :prod] and File.exists?(".env") do
  for line <- File.stream!(".env"),
      trimmed = String.trim(line),
      trimmed != "",
      not String.starts_with?(trimmed, "#"),
      [key | rest] = String.split(trimmed, "=", parts: 2),
      rest != [] do
    System.put_env(key, hd(rest))
  end
end

if config_env() == :prod do
  config :llm_proxy, LLMProxy.Repo,
    database: System.get_env("DATABASE_PATH", "./llm_proxy.db")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  config :llm_proxy, LLMProxyWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: secret_key_base,
    server: true
end

if config_env() in [:dev, :prod] do
  config :llm_proxy,
    master_key: System.get_env("MASTER_KEY"),
    public_url: System.get_env("PUBLIC_URL", ""),
    exa_api_key: System.get_env("EXA_API_KEY", ""),
    context7_api_key: System.get_env("CONTEXT7_API_KEY", ""),
    openrouter_api_keys: System.get_env("OPENROUTER_API_KEYS", ""),
    openai_api_keys: System.get_env("OPENAI_API_KEYS", ""),
    anthropic_api_keys: System.get_env("ANTHROPIC_API_KEYS", "")
end
