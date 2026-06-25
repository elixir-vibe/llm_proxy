import Config
import Dotenvy

if config_env() in [:dev, :prod] do
  ".env"
  |> source!()
  |> Map.merge(System.get_env())
  |> System.put_env()
end

if config_env() == :prod do
  quackdb_uri = System.get_env("QUACKDB_URI", "http://127.0.0.1:9494")
  quackdb_token = System.get_env("QUACKDB_TOKEN") || System.fetch_env!("MASTER_KEY")

  config :llm_proxy,
    repo: LLMProxy.QuackRepo,
    ecto_repos: [LLMProxy.QuackRepo],
    http: [port: String.to_integer(System.get_env("PORT", "4000"))],
    quackdb_server: [
      name: LLMProxy.QuackDBServer,
      duckdb: :managed,
      database: System.get_env("DATABASE_PATH", "./llm_proxy.duckdb"),
      endpoint: System.get_env("QUACKDB_ENDPOINT", "quack:localhost:9494"),
      uri: quackdb_uri,
      token: quackdb_token
    ]

  config :llm_proxy, LLMProxy.QuackRepo,
    uri: quackdb_uri,
    token: quackdb_token
end

if config_env() in [:dev, :prod] do
  fallbacks =
    case System.get_env("LLM_FALLBACKS") do
      nil -> %{}
      json -> Jason.decode!(json)
    end

  public_url = System.get_env("PUBLIC_URL", "")

  config :llm_proxy,
    master_key: System.get_env("MASTER_KEY"),
    public_url: public_url,
    providers: %{
      "anthropic" => %{api_keys: System.get_env("ANTHROPIC_API_KEYS", "")},
      "openai" => %{api_keys: System.get_env("OPENAI_API_KEYS", "")},
      "openrouter" => %{
        api_keys: System.get_env("OPENROUTER_API_KEYS", ""),
        http_referer: public_url
      }
    },
    fallbacks: fallbacks,
    max_retries: String.to_integer(System.get_env("LLM_MAX_RETRIES", "1"))
end
