import Config

if File.exists?(".env") do
  for line <- File.stream!(".env"),
      trimmed = String.trim(line),
      trimmed != "",
      not String.starts_with?(trimmed, "#"),
      [key, value] = String.split(trimmed, "=", parts: 2) do
    System.put_env(key, value)
  end
end

config :llm_proxy, LLMProxy.Repo,
  database: "llm_proxy_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :llm_proxy,
  master_key: System.get_env("MASTER_KEY", "test-master-key"),
  openrouter_api_keys: System.get_env("OPENROUTER_API_KEYS", ""),
  openai_api_keys: System.get_env("OPENAI_API_KEYS", ""),
  anthropic_api_keys: System.get_env("ANTHROPIC_API_KEYS", ""),
  exa_api_key: System.get_env("EXA_API_KEY", ""),
  context7_api_key: System.get_env("CONTEXT7_API_KEY", "")

config :logger, level: :warning
