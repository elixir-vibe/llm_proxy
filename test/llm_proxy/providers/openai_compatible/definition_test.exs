defmodule LLMProxy.Providers.OpenAICompatible.DefinitionTest do
  use ExUnit.Case

  alias LLMProxy.Providers.Result
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxyTestOpenAICompatibleProviderStub, as: ProviderStub
  alias Req.Test, as: ReqTest

  defmodule Provider do
    use LLMProxy.Providers.OpenAICompatible.Definition,
      name: "macro-openai-compatible",
      models: ["macro-model"],
      config_key: "macro-openai-compatible",
      title: "Macro Provider"
  end

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    TokenPool.clear_rate_limits()
    Application.put_env(:llm_proxy, :req_plug, {ReqTest, ProviderStub})

    Application.put_env(:llm_proxy, :providers, %{
      "macro-openai-compatible" => %{base_url: "https://macro.example/v1"}
    })

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :req_plug)
      Application.delete_env(:llm_proxy, :providers)
    end)

    :ok
  end

  test "generated provider calls OpenAI-compatible endpoints" do
    ReqTest.stub(ProviderStub, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer macro-token"]
      assert Plug.Conn.get_req_header(conn, "x-title") == ["Macro Provider"]

      ReqTest.json(conn, %{
        "id" => "resp-1",
        "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1}
      })
    end)

    {:ok, token} = Storage.add_token("macro-openai-compatible", "api-key", "macro-token")

    assert {:ok, %Result{response: %{"id" => "resp-1"}, token: picked_token}} =
             Provider.call(%{"model" => "macro-model"}, "user-1")

    assert picked_token.id == token.id
    assert Provider.models() == ["macro-model"]
  end
end
