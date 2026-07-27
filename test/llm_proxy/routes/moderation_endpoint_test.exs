defmodule LLMProxy.HTTP.Routes.ModerationEndpointTest do
  use ExUnit.Case

  alias LLMProxy.HTTP.Routes.ModerationEndpoint
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxyTestModerationsStub, as: ModerationsStub
  alias Req.Test, as: ReqTest

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    TokenPool.clear_rate_limits()

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :req_plug)
    end)
  end

  test "rejects missing input" do
    {:ok, _key, raw_key} = Storage.create_key("moderation-user")

    conn =
      TestSupport.json_conn(:post, "/", %{})
      |> TestSupport.put_bearer(raw_key)
      |> ModerationEndpoint.call(ModerationEndpoint.init([]))

    assert conn.status == 400
    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) == "input is required"
  end

  test "returns 503 when no OpenAI token is available" do
    {:ok, _key, raw_key} = Storage.create_key("moderation-user")

    conn =
      TestSupport.json_conn(:post, "/", %{"input" => "hello"})
      |> TestSupport.put_bearer(raw_key)
      |> ModerationEndpoint.call(ModerationEndpoint.init([]))

    assert conn.status == 503

    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) ==
             "No OpenAI token available"
  end

  test "normalizes upstream moderation errors" do
    Application.put_env(:llm_proxy, :req_plug, {ReqTest, ModerationsStub})

    ReqTest.stub(ModerationsStub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> ReqTest.json(%{
        "error" => %{
          "message" => "Invalid moderation input",
          "code" => "invalid_input",
          "headers" => %{"authorization" => "Bearer secret"}
        }
      })
    end)

    {:ok, _key, raw_key} = Storage.create_key("moderation-error-user")
    {:ok, _token} = Storage.add_token("openai", "api-key", "openai-token")

    conn =
      TestSupport.json_conn(:post, "/", %{"input" => "hello"})
      |> TestSupport.put_bearer(raw_key)
      |> ModerationEndpoint.call(ModerationEndpoint.init([]))

    assert conn.status == 400

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "message" => "Invalid moderation input",
               "type" => "invalid_input",
               "code" => "invalid_input",
               "status" => 400
             }
           }

    refute conn.resp_body =~ "authorization"
    refute conn.resp_body =~ "secret"
  end

  test "proxies moderation requests" do
    Application.put_env(:llm_proxy, :req_plug, {ReqTest, ModerationsStub})

    ReqTest.stub(ModerationsStub, fn conn ->
      ReqTest.json(conn, %{"results" => [%{"flagged" => false}]})
    end)

    {:ok, _key, raw_key} = Storage.create_key("moderation-user")
    {:ok, _token} = Storage.add_token("openai", "api-key", "openai-token")

    conn =
      TestSupport.json_conn(:post, "/", %{"input" => "hello"})
      |> Plug.Conn.put_req_header("x-request-id", "moderations-request-id-123")
      |> TestSupport.put_bearer(raw_key)
      |> ModerationEndpoint.call(ModerationEndpoint.init([]))

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "x-request-id") == ["moderations-request-id-123"]

    assert Plug.Conn.get_resp_header(conn, "x-llm-proxy-trace-id") == [
             "moderations-request-id-123"
           ]

    assert Jason.decode!(conn.resp_body) == %{"results" => [%{"flagged" => false}]}
  end
end
