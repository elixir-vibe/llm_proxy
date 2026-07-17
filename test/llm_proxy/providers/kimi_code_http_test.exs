defmodule LLMProxy.Providers.KimiCodeHTTPTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{KimiCode, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxyTestKimiCodeStub, as: KimiCodeStub
  alias Req.Test, as: ReqTest

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    TokenPool.clear_rate_limits()
    Application.put_env(:llm_proxy, :req_plug, {ReqTest, KimiCodeStub})

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :req_plug)
      Application.delete_env(:llm_proxy, :providers)
    end)
  end

  test "call/2 sends Kimi Code keys directly to the Kimi coding API" do
    Application.put_env(:llm_proxy, :providers, %{
      "kimi-code" => %{base_url: "https://api.kimi.com/coding/v1"}
    })

    ReqTest.stub(KimiCodeStub, fn conn ->
      assert conn.request_path == "/coding/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer kimi-code-token"]
      assert Plug.Conn.get_req_header(conn, "http-referer") == []

      assert %{"model" => "k3", "messages" => [%{"role" => "user"}]} =
               Jason.decode!(ReqTest.raw_body(conn))

      ReqTest.json(conn, %{
        "id" => "kimi-response-1",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "OK"}}],
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 1}
      })
    end)

    {:ok, token} = Storage.add_token("kimi-code", "api-key", "kimi-code-token")

    assert {:ok, %Result{response: %{"id" => "kimi-response-1"}, token: picked_token}} =
             KimiCode.call(
               %{"model" => "k3", "messages" => [%{"role" => "user", "content" => "hi"}]},
               "user-1"
             )

    assert picked_token.id == token.id
  end

  test "provider has no unaliased public models" do
    assert KimiCode.models() == []
    assert KimiCode.name() == "kimi-code"
  end
end
