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

  config :llm_proxy,
    repo: LLMProxy.Storage.Repo.QuackDB,
    ecto_repos: [LLMProxy.Storage.Repo.QuackDB],
    http: [port: String.to_integer(System.get_env("PORT", "4000"))],
    quackdb_server: [
      name: LLMProxy.QuackDBServer,
      duckdb: :managed,
      database: System.get_env("DATABASE_PATH", "./llm_proxy.duckdb"),
      endpoint: System.get_env("QUACKDB_ENDPOINT", "quack:localhost:9494")
    ]

  config :llm_proxy, LLMProxy.Storage.Repo.QuackDB,
    uri: quackdb_uri,
    priv: "priv/repo"
end

if config_env() in [:dev, :prod] do
  case System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
    endpoint when is_binary(endpoint) and endpoint != "" ->
      config :opentelemetry, traces_exporter: :otlp
      config :opentelemetry_exporter, otlp_endpoint: endpoint

    _other ->
      config :opentelemetry, traces_exporter: :none
  end

  fallbacks =
    case System.get_env("LLM_FALLBACKS") do
      nil -> %{}
      json -> Jason.decode!(json)
    end

  public_url = System.get_env("PUBLIC_URL", "")

  body_limit_bytes =
    case Integer.parse(System.get_env("LLM_PROXY_BODY_LIMIT_BYTES", "32000000")) do
      {bytes, ""} when bytes > 0 ->
        bytes

      _other ->
        raise "LLM_PROXY_BODY_LIMIT_BYTES must be a positive integer"
    end

  provider_connect_timeout_ms =
    case Integer.parse(System.get_env("LLM_PROXY_PROVIDER_CONNECT_TIMEOUT_MS", "10000")) do
      {timeout, ""} when timeout > 0 ->
        timeout

      _other ->
        raise "LLM_PROXY_PROVIDER_CONNECT_TIMEOUT_MS must be a positive integer"
    end

  provider_key_seeds =
    case System.get_env("LLM_PROXY_PROVIDER_KEYS") do
      nil -> %{}
      json -> Jason.decode!(json)
    end

  provider_token_keyring =
    case System.get_env("LLM_PROXY_PROVIDER_TOKEN_KEYRING") do
      value when value in [nil, ""] ->
        nil

      json ->
        case Jason.decode(json) do
          {:ok, keyring} -> keyring
          {:error, _reason} -> raise "invalid provider token keyring JSON"
        end
    end

  config :llm_proxy,
    master_key: System.get_env("MASTER_KEY"),
    provider_token_keyring: provider_token_keyring,
    provider_key_seeds: provider_key_seeds,
    public_url: public_url,
    rpc_socket: System.get_env("LLM_PROXY_RPC_SOCKET"),
    providers: %{
      "anthropic" => %{api_keys: System.get_env("ANTHROPIC_API_KEYS", "")},
      "openai" => %{api_keys: System.get_env("OPENAI_API_KEYS", "")},
      "openrouter" => %{
        api_keys: System.get_env("OPENROUTER_API_KEYS", ""),
        http_referer: public_url
      },
      "openai-codex" => %{oauth_tokens: System.get_env("OPENAI_CODEX_TOKENS", "")}
    },
    fallbacks: fallbacks,
    max_retries: String.to_integer(System.get_env("LLM_MAX_RETRIES", "1")),
    provider_connect_timeout_ms: provider_connect_timeout_ms,
    body_limit_bytes: body_limit_bytes
end
