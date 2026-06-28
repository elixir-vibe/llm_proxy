import Config

if Code.ensure_loaded?(Dotenvy) do
  ".env"
  |> Dotenvy.source!()
  |> Map.merge(System.get_env())
  |> System.put_env()
end

config :llm_proxy, LLMProxy.Storage.Repo.SQLite,
  database: "llm_proxy_test.db",
  priv: "priv/repo",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :llm_proxy,
  master_key: System.get_env("MASTER_KEY", "test-master-key"),
  providers: %{
    "anthropic" => %{api_keys: System.get_env("ANTHROPIC_API_KEYS", "")},
    "openai" => %{api_keys: System.get_env("OPENAI_API_KEYS", "")},
    "openrouter" => %{api_keys: System.get_env("OPENROUTER_API_KEYS", "")},
    "openai-codex" => %{oauth_tokens: System.get_env("OPENAI_CODEX_TOKENS", "")}
  }

config :llm_proxy,
  http: [port: 4002]

config :opentelemetry, traces_exporter: :none

config :logger, level: :warning
