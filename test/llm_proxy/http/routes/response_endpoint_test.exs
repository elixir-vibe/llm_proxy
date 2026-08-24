defmodule LLMProxy.HTTP.Routes.ResponseEndpointTest do
  use ExUnit.Case

  alias LLMProxy.HTTP.Routes.ResponseEndpoint
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.Stream.Event
  alias LLMProxy.TestSupport

  defmodule FakeResponsesProvider do
    def name, do: "fake-responses"

    def models,
      do: [
        "fake-responses-model",
        "fake-responses-error",
        "fake-responses-rate-limited",
        "fake-responses-preflight-failure",
        "fake-responses-midstream-failure"
      ]

    def call_native(%{"model" => "fake-responses-error"}, _user_id) do
      {:error, Result.error("response failed", 500, nil)}
    end

    def call_native(%{"model" => "fake-responses-rate-limited"}, _user_id) do
      {:error,
       Result.error(
         "slow down",
         429,
         Application.fetch_env!(:llm_proxy, :responses_test_token)
       )}
    end

    def call_native(_body, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "resp-1",
           "usage" => %{"input_tokens" => 9, "output_tokens" => 4}
         },
         nil
       )}
    end

    def stream_native(
          %{"model" => "fake-responses-preflight-failure", "stream" => true},
          _user_id
        ) do
      stream = Stream.map([:request], fn _request -> raise "responses model unavailable" end)
      {:ok, Result.stream(stream, nil)}
    end

    def stream_native(
          %{"model" => "fake-responses-midstream-failure", "stream" => true},
          _user_id
        ) do
      stream =
        Stream.concat(
          [Event.new(%{"type" => "response.output_text.delta", "delta" => "partial"})],
          Stream.map([:failure], fn _event -> raise "responses upstream disconnected" end)
        )

      {:ok, Result.stream(stream, nil)}
    end

    def stream_native(%{"stream" => true}, _user_id) do
      {:ok,
       Result.stream(
         [
           Event.new(%{
             "type" => "response.completed",
             "response" => %{"usage" => %{"input_tokens" => 9, "output_tokens" => 4}}
           })
         ],
         nil
       )}
    end

    def stream_error(reason, token), do: Result.error(Exception.message(reason), 400, token)
  end

  setup do
    TestSupport.checkout_repo()
    Registry.register(FakeResponsesProvider)

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :responses_test_token)
    end)

    :ok
  end

  test "returns native responses and tracks usage" do
    {:ok, _key, raw_key} = Storage.create_key("responses-user")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-responses-model",
        "input" => [%{"role" => "user", "content" => "hello"}],
        "stream" => false
      })
      |> Plug.Conn.put_req_header("x-request-id", "responses-request-id-123")
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "x-request-id") == ["responses-request-id-123"]
    assert Plug.Conn.get_resp_header(conn, "x-llm-proxy-trace-id") == ["responses-request-id-123"]
    assert Jason.decode!(conn.resp_body)["id"] == "resp-1"

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 9
    assert updated_key.output_tokens == 4
  end

  test "streams native responses" do
    {:ok, _key, raw_key} = Storage.create_key("responses-stream")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-responses-model",
        "input" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 200
    assert conn.state == :chunked

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 9
    assert updated_key.output_tokens == 4
  end

  test "returns HTTP errors for responses streams rejected before the first event" do
    {:ok, _key, raw_key} = Storage.create_key("responses-preflight-failure")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-responses-preflight-failure",
        "input" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 400
    assert conn.state == :sent

    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) ==
             "responses model unavailable"
  end

  test "renders responses error events and DONE after midstream failures" do
    {:ok, _key, raw_key} = Storage.create_key("responses-midstream-failure")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-responses-midstream-failure",
        "input" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "partial"
    assert conn.resp_body =~ "responses upstream disconnected"
    assert conn.resp_body =~ ~s("type":"error")
    assert conn.resp_body =~ "data: [DONE]"
  end

  test "rejects invalid input message shapes" do
    {:ok, _key, raw_key} = Storage.create_key("responses-invalid-shape")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-responses-model",
        "input" => [%{"role" => "wat", "content" => "hello"}],
        "stream" => false
      })
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 400
    assert get_in(Jason.decode!(conn.resp_body), ["error", "type"]) == "invalid_message"
  end

  test "returns provider rate-limit errors" do
    {:ok, _key, raw_key} = Storage.create_key("responses-user")
    {:ok, token} = Storage.add_token("openai", "api-key", "token-for-rate-limit")
    Application.put_env(:llm_proxy, :responses_test_token, token)

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-responses-rate-limited",
        "input" => [%{"role" => "user", "content" => "hello"}],
        "stream" => false
      })
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 429
    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) == "slow down"
  end

  test "returns provider errors" do
    {:ok, _key, raw_key} = Storage.create_key("responses-user")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-responses-error",
        "input" => [%{"role" => "user", "content" => "hello"}],
        "stream" => false
      })
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 500
    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) == "response failed"
  end

  test "returns 404 for unknown routes" do
    {:ok, _key, raw_key} = Storage.create_key("route-user")

    conn =
      Plug.Test.conn(:get, "/missing")
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 404
  end

  test "returns structured errors for unknown models" do
    {:ok, _key, raw_key} = Storage.create_key("responses-user")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "missing-model",
        "input" => [%{"role" => "user", "content" => "hello"}],
        "stream" => false
      })
      |> TestSupport.put_bearer(raw_key)
      |> ResponseEndpoint.call(ResponseEndpoint.init([]))

    assert conn.status == 404

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "message" => "Model 'missing-model' not found",
               "type" => "not_found_error",
               "code" => "not_found_error",
               "status" => 404
             }
           }
  end
end
