defmodule LLMProxy.Config.ProviderTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Config.Provider

  test "load/2 merges TOML config when file exists" do
    path = tmp_path("llm-proxy-config.toml")

    File.write!(path, """
    [routing]
    max_retries = 2
    replay_policy = "safe_only"

    [providers.openai-codex]
    base_url = "https://chatgpt.com/backend-api"

    [[models]]
    name = "codex"

    [[models.routes]]
    to = "openai-codex"
    model = "gpt-5.3-codex-spark"
    """)

    config = Provider.load([], path: path)

    assert Keyword.get(config, :llm_proxy)[:providers]["openai-codex"].base_url ==
             "https://chatgpt.com/backend-api"

    llm_proxy = Keyword.fetch!(config, :llm_proxy)

    assert [%{name: "codex", routes: [%{to: "openai-codex"}]}] = llm_proxy[:models]
    assert llm_proxy[:max_retries] == 2
    assert llm_proxy[:replay_policy] == :safe_only
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
