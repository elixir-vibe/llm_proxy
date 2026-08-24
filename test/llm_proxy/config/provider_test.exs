defmodule LLMProxy.Config.ProviderTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Config.Provider
  alias LLMProxy.Storage.Repo.QuackDB

  test "load/2 merges TOML config when file exists" do
    path = tmp_path("llm-proxy-config.toml")

    File.write!(path, """
    [server]
    port = 4101
    public_url = "https://llm.example.com"

    [storage]
    database = "/var/lib/llm-proxy/main.duckdb"
    quackdb_uri = "http://127.0.0.1:9494"

    [routing]
    max_retries = 2
    replay_policy = "safe_only"

    [telemetry]
    otlp_endpoint = "http://127.0.0.1:4318"

    [provider_tokens]
    allow_plaintext = false

    [providers.openai-codex]
    base_url = "https://chatgpt.com/backend-api"

    [[models]]
    name = "codex"

    [[models.routes]]
    to = "openai-codex"
    model = "gpt-5.3-codex-spark"
    """)

    initial = [
      llm_proxy: [
        http: [ip: {127, 0, 0, 1}, port: 4000],
        quackdb_server: [name: LLMProxy.QuackDBServer, duckdb: :managed]
      ],
      opentelemetry: [span_processor: :batch, traces_exporter: :none]
    ]

    config = Provider.load(initial, path: path)

    assert Keyword.get(config, :llm_proxy)[:providers]["openai-codex"].base_url ==
             "https://chatgpt.com/backend-api"

    llm_proxy = Keyword.fetch!(config, :llm_proxy)

    assert [%{name: "codex", routes: [%{to: "openai-codex"}]}] = llm_proxy[:models]
    assert llm_proxy[:http] == [ip: {127, 0, 0, 1}, port: 4101]
    assert llm_proxy[:public_url] == "https://llm.example.com"

    assert llm_proxy[:quackdb_server] == [
             name: LLMProxy.QuackDBServer,
             duckdb: :managed,
             database: "/var/lib/llm-proxy/main.duckdb"
           ]

    assert llm_proxy[QuackDB] == [uri: "http://127.0.0.1:9494"]
    assert llm_proxy[:max_retries] == 2
    assert llm_proxy[:replay_policy] == :safe_only
    refute llm_proxy[:provider_token_allow_plaintext]
    assert config[:opentelemetry] == [span_processor: :batch, traces_exporter: :otlp]
    assert config[:opentelemetry_exporter] == [otlp_endpoint: "http://127.0.0.1:4318"]
  end

  test "load/2 reports invalid TOML without echoing file contents" do
    path = tmp_path("invalid.toml")
    File.write!(path, ~s([server]\nport = "seeded-secret"))

    error =
      assert_raise ArgumentError, "server.port must be an integer from 1 to 65535", fn ->
        Provider.load([], path: path)
      end

    refute Exception.message(error) =~ "seeded-secret"
  end

  test "load/2 is a no-op when file is absent" do
    config = [llm_proxy: [http_enabled: false]]

    assert Provider.load(config, path: tmp_path("missing.toml")) == config
  end

  test "init/1 uses env-overridable default path" do
    assert [path: {:system, "LLM_PROXY_CONFIG_TOML", "/etc/llm-proxy/config.toml"}] =
             Provider.init([])
  end

  test "load/2 resolves init system path from environment" do
    path = tmp_path("env-config.toml")
    env = "LLM_PROXY_CONFIG_TOML"

    File.write!(path, """
    [[models]]
    name = "codex"
    """)

    System.put_env(env, path)

    assert [llm_proxy: [models: [%{name: "codex", routes: []}]]] =
             Provider.load([], Provider.init([]))
  after
    System.delete_env("LLM_PROXY_CONFIG_TOML")
  end

  defp tmp_path(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "llm_proxy_config_provider_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Path.join(dir, name)
  end
end
