defmodule LLMProxy.HTTP.Routes.SetupTest do
  use ExUnit.Case

  alias LLMProxy.HTTP.Routes.Setup
  alias LLMProxy.Providers.Registry
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  defmodule SetupProvider do
    def name, do: "setup-provider"
    def models, do: ["setup-model", "setup-model-20260101"]
  end

  setup do
    TestSupport.checkout_repo()
    Registry.register(SetupProvider)
    Application.put_env(:llm_proxy, :public_url, "https://proxy.example")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :public_url)
    end)
  end

  test "serves install script and models" do
    install_conn = Plug.Test.conn(:get, "/install.sh") |> Setup.call(Setup.init([]))
    models_conn = Plug.Test.conn(:get, "/models") |> Setup.call(Setup.init([]))

    assert install_conn.status == 200
    assert install_conn.resp_body =~ "https://proxy.example"
    assert models_conn.status == 200
    assert Enum.any?(Jason.decode!(models_conn.resp_body), &(&1["id"] == "setup-model"))
  end

  test "returns authenticated config, env, and extension output" do
    {:ok, _key, raw_key} = Storage.create_key("setup-user", %{allowed_models: ["setup-model"]})

    config_conn =
      Plug.Test.conn(:get, "/config?key=#{raw_key}")
      |> Setup.call(Setup.init([]))

    env_conn =
      Plug.Test.conn(:get, "/env")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw_key}")
      |> Setup.call(Setup.init([]))

    extension_conn =
      Plug.Test.conn(:get, "/extension?key=#{raw_key}") |> Setup.call(Setup.init([]))

    assert config_conn.status == 200

    assert get_in(Jason.decode!(config_conn.resp_body), ["providers", "llm-proxy", "baseUrl"]) ==
             "https://proxy.example"

    assert get_in(Jason.decode!(config_conn.resp_body), ["providers", "llm-proxy", "models"]) == [
             %{"id" => "setup-model", "object" => "model", "owned_by" => "setup-provider"}
           ]

    assert env_conn.status == 200
    assert Jason.decode!(env_conn.resp_body) == %{"PROVIDER_API_KEY" => raw_key}
    assert extension_conn.status == 200
    assert extension_conn.resp_body =~ "registerProvider('llm-proxy'"
    assert extension_conn.resp_body =~ "setup-model"
  end

  test "accepts bearer auth for config" do
    {:ok, _key, raw_key} =
      Storage.create_key("setup-bearer-user", %{allowed_models: ["setup-model"]})

    conn =
      Plug.Test.conn(:get, "/config")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw_key}")
      |> Setup.call(Setup.init([]))

    assert conn.status == 200

    assert get_in(Jason.decode!(conn.resp_body), ["providers", "llm-proxy", "models"]) == [
             %{"id" => "setup-model", "object" => "model", "owned_by" => "setup-provider"}
           ]
  end

  test "uses request host when public url is not configured" do
    Application.delete_env(:llm_proxy, :public_url)
    {:ok, _key, raw_key} = Storage.create_key("setup-host-user")

    %Plug.Conn{} = conn = Plug.Test.conn(:get, "/config?key=#{raw_key}")

    conn =
      %{conn | host: "llm.example"}
      |> Setup.call(Setup.init([]))

    assert conn.status == 200

    assert get_in(Jason.decode!(conn.resp_body), ["providers", "llm-proxy", "baseUrl"]) ==
             "https://llm.example"
  end

  test "rejects invalid api keys" do
    conn = Plug.Test.conn(:get, "/config?key=missing") |> Setup.call(Setup.init([]))
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Invalid API key"}
  end
end
