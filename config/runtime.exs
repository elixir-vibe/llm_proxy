import Config
import Dotenvy

if config_env() in [:dev, :prod] do
  ".env"
  |> source!()
  |> Map.merge(System.get_env())
  |> System.put_env()
end

if config_env() == :prod do
  config :llm_proxy,
    repo: LLMProxy.Storage.Repo.QuackDB,
    ecto_repos: [LLMProxy.Storage.Repo.QuackDB],
    quackdb_server: [
      name: LLMProxy.QuackDBServer,
      duckdb: :managed,
      database: "./llm_proxy.duckdb",
      endpoint: "quack:localhost:9494"
    ]

  config :llm_proxy, LLMProxy.Storage.Repo.QuackDB,
    uri: "http://127.0.0.1:9494",
    priv: "priv/repo"
end

if config_env() in [:dev, :prod] do
  provider_key_seeds =
    case System.get_env("LLM_PROXY_PROVIDER_KEYS") do
      value when value in [nil, ""] ->
        %{}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = seeds} ->
            valid? =
              Enum.all?(seeds, fn
                {pool, tokens} when is_binary(pool) and is_list(tokens) ->
                  pool != "" and Enum.all?(tokens, &(is_binary(&1) and &1 != ""))

                _entry ->
                  false
              end)

            if valid?, do: seeds, else: raise("invalid LLM_PROXY_PROVIDER_KEYS shape")

          {:ok, _other} ->
            raise "LLM_PROXY_PROVIDER_KEYS must be a JSON object"

          {:error, _reason} ->
            raise "invalid LLM_PROXY_PROVIDER_KEYS JSON"
        end
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
    provider_key_seeds: provider_key_seeds
end
