defmodule LLMProxy.Config.TOMLTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Config.TOML
  alias LLMProxy.Storage.Repo.QuackDB

  test "decodes the complete standalone configuration into application config" do
    input = """
    [server]
    port = 4101
    public_url = "https://llm.example.com"
    body_limit_bytes = 64000000
    rpc_socket = "/run/llm-proxy/rpc.sock"

    [storage]
    database = "/var/lib/llm-proxy/main.duckdb"
    quackdb_uri = "http://127.0.0.1:9494"
    quackdb_endpoint = "quack:localhost:9494"

    [routing]
    max_retries = 2
    replay_policy = "allow_uncertain"
    provider_connect_timeout_ms = 15000

    [provider_tokens]
    allow_plaintext = false

    [provider_usage]
    auto_refresh = false
    refresh_interval_ms = 120000
    request_timeout_ms = 5000
    stale_after_ms = 600000

    [telemetry]
    otlp_endpoint = "http://127.0.0.1:4318"

    [providers.configured]
    adapter = "openai"
    base_url = "https://configured.example/v1"
    token_pool = "configured-production"

    [providers.anthropic.conversion_defaults]
    max_tokens = 4096

    [[models]]
    name = "fast"
    routing = "lowest_cost"

    [[models.routes]]
    to = "configured"
    model = "upstream-model"
    timeout = 15000
    order = 1
    """

    assert {:ok, config} = TOML.decode(input)
    llm_proxy = Keyword.fetch!(config, :llm_proxy)

    assert llm_proxy[:http] == [port: 4101]
    assert llm_proxy[:public_url] == "https://llm.example.com"
    assert llm_proxy[:body_limit_bytes] == 64_000_000
    assert llm_proxy[:rpc_socket] == "/run/llm-proxy/rpc.sock"
    assert llm_proxy[:max_retries] == 2
    assert llm_proxy[:replay_policy] == :allow_uncertain
    assert llm_proxy[:provider_connect_timeout_ms] == 15_000
    refute llm_proxy[:provider_token_allow_plaintext]
    refute llm_proxy[:provider_usage_auto_refresh]
    assert llm_proxy[:provider_usage_refresh_interval_ms] == 120_000
    assert llm_proxy[:provider_usage_request_timeout_ms] == 5_000
    assert llm_proxy[:provider_usage_stale_after_ms] == 600_000

    assert llm_proxy[:quackdb_server][:database] == "/var/lib/llm-proxy/main.duckdb"
    assert llm_proxy[:quackdb_server][:endpoint] == "quack:localhost:9494"

    assert llm_proxy[QuackDB] == [uri: "http://127.0.0.1:9494"]

    assert llm_proxy[:providers] == %{
             "anthropic" => %{conversion_defaults: %{max_tokens: 4096}},
             "configured" => %{
               adapter: "openai",
               base_url: "https://configured.example/v1",
               token_pool: "configured-production"
             }
           }

    assert llm_proxy[:models] == [
             %{
               name: "fast",
               routing: :lowest_cost,
               routes: [
                 %{
                   to: "configured",
                   model: "upstream-model",
                   timeout_ms: 15_000,
                   order: 1
                 }
               ]
             }
           ]

    assert config[:opentelemetry] == [traces_exporter: :otlp]
    assert config[:opentelemetry_exporter] == [otlp_endpoint: "http://127.0.0.1:4318"]
  end

  test "supports catalog.models as an alternate TOML nesting" do
    input = """
    [[catalog.models]]
    name = "codex"

    [[catalog.models.routes]]
    to = "openai-codex"
    model = "gpt-5.3-codex-spark"
    """

    assert {:ok, [llm_proxy: config]} = TOML.decode(input)

    assert config[:models] == [
             %{name: "codex", routes: [%{to: "openai-codex", model: "gpt-5.3-codex-spark"}]}
           ]
  end

  test "rejects credentials and encryption keys in TOML" do
    assert_raise ArgumentError, ~r/unsupported TOML configuration key/, fn ->
      TOML.decode(~s([providers.openai]\napi_keys = "must-not-live-in-toml"))
    end

    assert_raise ArgumentError, ~r/provider_tokens contains unsupported configuration keys/, fn ->
      TOML.decode(~s([provider_tokens]\nkeys = "must-not-live-in-toml"))
    end
  end

  test "rejects unknown sections and invalid standalone values" do
    assert_raise ArgumentError, ~r/top-level contains unsupported configuration keys/, fn ->
      TOML.decode("[unknown]\nvalue = 1")
    end

    assert_raise ArgumentError, ~r/server.port must be an integer/, fn ->
      TOML.decode("[server]\nport = 70000")
    end

    assert_raise ArgumentError, ~r/max_retries must be a non-negative integer/, fn ->
      TOML.decode("[routing]\nmax_retries = -1")
    end

    assert_raise ArgumentError, ~r/replay_policy must be safe_only or allow_uncertain/, fn ->
      TOML.decode(~s([routing]\nreplay_policy = "always"))
    end

    assert_raise ArgumentError, ~r/otlp_endpoint must be an absolute HTTP/, fn ->
      TOML.decode(~s([telemetry]\notlp_endpoint = "localhost:4318"))
    end

    assert_raise ArgumentError, ~r/refresh_interval_ms must be from 60000 through 3600000/, fn ->
      TOML.decode("[provider_usage]\nrefresh_interval_ms = 59999")
    end

    assert_raise ArgumentError, ~r/stale_after_ms must be from 300000 through 86400000/, fn ->
      TOML.decode("[provider_usage]\nstale_after_ms = 120000")
    end
  end

  test "decodes explicit GLM usage source settings" do
    input = """
    [providers.glm]
    adapter = "zai_coding_plan"
    base_url = "https://api.z.ai/api/coding/paas/v4"
    token_pool = "glm-production"
    usage_adapter = "glm"
    usage_auth_scheme = "bearer"
    usage_paths = ["/api/monitor/usage"]
    """

    assert {:ok, [llm_proxy: config]} = TOML.decode(input)

    assert config[:providers] == %{
             "glm" => %{
               adapter: "zai_coding_plan",
               base_url: "https://api.z.ai/api/coding/paas/v4",
               token_pool: "glm-production",
               usage_adapter: "glm",
               usage_auth_scheme: "bearer",
               usage_paths: ["/api/monitor/usage"]
             }
           }
  end

  test "returns TOML parser errors" do
    assert {:error, {:invalid_toml, _reason}} = TOML.decode("[invalid]\na = 1 b = 2")
  end

  test "decodes a catalog public model allowlist, including an empty list" do
    assert {:ok, [llm_proxy: config]} =
             TOML.decode(~s([catalog]\npublic_models = ["codex", "glm", "codex"]))

    assert config[:public_models] == ["codex", "glm"]

    assert {:ok, [llm_proxy: empty_config]} =
             TOML.decode("[catalog]\npublic_models = []")

    assert empty_config[:public_models] == []
  end

  test "rejects invalid or top-level public model allowlists" do
    assert_raise ArgumentError, ~r/catalog.public_models must be an array/, fn ->
      TOML.decode(~s([catalog]\npublic_models = "codex"))
    end

    assert_raise ArgumentError, ~r/contain only non-empty model IDs/, fn ->
      TOML.decode(~s([catalog]\npublic_models = [" "]))
    end

    assert_raise ArgumentError, ~r/top-level contains unsupported configuration keys/, fn ->
      TOML.decode(~s(public_models = ["codex"]))
    end
  end
end
