defmodule LLMProxy.Config.ProviderTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Config.Provider

  test "load/2 merges TOML config when file exists" do
    path = tmp_path("llm-proxy-config.toml")

    File.write!(path, """
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

    assert [%{name: "codex", routes: [%{to: "openai-codex"}]}] =
             Keyword.get(config, :llm_proxy)[:models]
  end

  test "load/2 is a no-op when file is absent" do
    config = [llm_proxy: [http_enabled: false]]

    assert Provider.load(config, path: tmp_path("missing.toml")) == config
  end

  test "init/1 uses env-overridable default path" do
    assert [path: {:system, "LLM_PROXY_CONFIG_TOML", "/etc/llm-proxy/config.toml"}] =
             Provider.init([])
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
