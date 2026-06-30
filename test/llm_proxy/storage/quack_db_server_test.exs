defmodule LLMProxy.Storage.QuackDBServerTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Storage.QuackDBServer
  alias LLMProxy.Storage.Repo.QuackDB, as: QuackDBRepo

  setup do
    original = Application.get_env(:llm_proxy, QuackDBRepo)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:llm_proxy, QuackDBRepo)
      else
        Application.put_env(:llm_proxy, QuackDBRepo, original)
      end
    end)
  end

  test "server_options/1 lets QuackDB derive the URI from the endpoint" do
    assert QuackDBServer.server_options(
             endpoint: "quack:localhost:9494",
             uri: "http://127.0.0.1:9494",
             database: ":memory:"
           ) == [endpoint: "quack:localhost:9494", database: ":memory:"]
  end

  test "update_repo_config/1 adds generated server credentials without dropping repo options" do
    Application.put_env(:llm_proxy, QuackDBRepo, priv: "priv/repo")

    assert :ok = QuackDBServer.update_repo_config(uri: "http://[::1]:9494", token: "generated")

    assert Application.get_env(:llm_proxy, QuackDBRepo) == [
             priv: "priv/repo",
             uri: "http://[::1]:9494",
             token: "generated"
           ]
  end
end
