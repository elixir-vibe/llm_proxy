defmodule LLMProxy.Providers.OpenRouterHTTPTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{OpenRouter, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxyTestOpenRouterStub, as: OpenRouterStub
  alias Req.Test, as: ReqTest

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    TokenPool.clear_rate_limits()
    Application.put_env(:llm_proxy, :req_plug, {ReqTest, OpenRouterStub})

    Application.put_env(:llm_proxy, :providers, %{
      "openrouter" => %{http_referer: "https://proxy.example"}
    })

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :req_plug)
      Application.delete_env(:llm_proxy, :providers)
    end)
  end

  test "call/2 sets OpenRouter-specific headers" do
    ReqTest.stub(OpenRouterStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer openrouter-token"]
      assert Plug.Conn.get_req_header(conn, "http-referer") == ["https://proxy.example"]
      assert Plug.Conn.get_req_header(conn, "x-title") == ["LLM Proxy"]

      ReqTest.json(conn, %{
        "id" => "resp-1",
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 3}
      })
    end)

    {:ok, token} = Storage.add_token("openrouter", "api-key", "openrouter-token")

    assert {:ok, %Result{response: %{"id" => "resp-1"}, token: picked_token}} =
             OpenRouter.call(%{"model" => "openrouter/model"}, "user-1")

    assert picked_token.id == token.id
  end
end
