defmodule LLMProxy.Providers.AnthropicHTTPTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{Anthropic, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxyTestAnthropicStub, as: AnthropicStub
  alias Req.Test, as: ReqTest

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    TokenPool.clear_rate_limits()
    Application.put_env(:llm_proxy, :req_plug, {ReqTest, AnthropicStub})

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :req_plug)
    end)
  end

  test "call/2 forwards native Anthropic format" do
    ReqTest.stub(AnthropicStub, fn conn ->
      assert conn.request_path == "/v1/messages"
      body = Jason.decode!(ReqTest.raw_body(conn))

      assert body["messages"] == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}
             ]

      assert body["max_tokens"] == 4096

      ReqTest.json(conn, %{
        "id" => "msg_1",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
      })
    end)

    {:ok, token} = Storage.add_token("anthropic", "api-key", "anthropic-token")

    assert {:ok, %Result{response: %{"id" => "msg_1"}, token: picked_token}} =
             Anthropic.call(
               %{
                 "model" => "claude",
                 "max_tokens" => 4096,
                 "messages" => [
                   %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}
                 ]
               },
               "user-1"
             )

    assert picked_token.id == token.id
  end

  test "call_native/2 forwards native anthropic bodies without conversion" do
    ReqTest.stub(AnthropicStub, fn conn ->
      body = Jason.decode!(ReqTest.raw_body(conn))

      assert body["messages"] == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}
             ]

      ReqTest.json(conn, %{
        "id" => "msg_2",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
      })
    end)

    {:ok, _token} = Storage.add_token("anthropic", "api-key", "anthropic-token")

    assert {:ok, %Result{response: %{"id" => "msg_2"}}} =
             Anthropic.call_native(
               %{
                 "messages" => [
                   %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}
                 ]
               },
               "user-1"
             )
  end
end
