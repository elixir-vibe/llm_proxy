defmodule LLMProxy.Providers.OpenAIHTTPTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{OpenAI, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxyTestOpenAIStub, as: OpenAIStub
  alias Req.Test, as: ReqTest

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    TokenPool.clear_rate_limits()
    Application.put_env(:llm_proxy, :req_plug, {ReqTest, OpenAIStub})

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :req_plug)
    end)
  end

  test "call/2 uses the configured token and returns the response" do
    ReqTest.stub(OpenAIStub, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer openai-token"]

      ReqTest.json(conn, %{
        "id" => "chatcmpl_1",
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2}
      })
    end)

    {:ok, token} = Storage.add_token("openai", "api-key", "openai-token")

    assert {:ok, %Result{response: %{"id" => "chatcmpl_1"}, token: picked_token}} =
             OpenAI.call(%{"model" => "gpt-4o"}, "user-1")

    assert picked_token.id == token.id
  end
end
