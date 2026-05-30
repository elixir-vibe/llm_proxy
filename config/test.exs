import Config

if Code.ensure_loaded?(Dotenvy) do
  ".env"
  |> Dotenvy.source!()
  |> Map.merge(System.get_env())
  |> System.put_env()
end

config :llm_proxy, LLMProxy.Repo,
  database: "llm_proxy_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :llm_proxy,
  master_key: System.get_env("MASTER_KEY", "test-master-key"),
  openrouter_api_keys: System.get_env("OPENROUTER_API_KEYS", ""),
  openai_api_keys: System.get_env("OPENAI_API_KEYS", ""),
  anthropic_api_keys: System.get_env("ANTHROPIC_API_KEYS", "")

config :llm_proxy, LLMProxy.Web.Endpoint,
  http: [port: 4002],
  secret_key_base: "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-test-only!!!",
  server: false

config :opentelemetry, traces_exporter: :none

config :logger, level: :warning
