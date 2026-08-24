defmodule LLMProxy.HTTP.Routes.MessageEndpointTest do
  use ExUnit.Case

  alias LLMProxy.{ConcurrencyLimiter, Limit}
  alias LLMProxy.HTTP.Routes.MessageEndpoint
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.Stream.Event
  alias LLMProxy.TestSupport

  defmodule FakeMessagesProvider do
    def name, do: "fake-messages"

    def models,
      do: [
        "fake-messages-model",
        "fake-messages-error",
        "fake-messages-auth-error",
        "fake-messages-invalid",
        "fake-messages-preflight-failure",
        "fake-messages-midstream-failure"
      ]

    def call_native(%{"model" => "fake-messages-error"}, _user_id) do
      {:error, Result.error("provider failed", 429, nil)}
    end

    def call_native(%{"model" => "fake-messages-auth-error"}, _user_id) do
      {:error, Result.error("auth failed", 401, nil)}
    end

    def call_native(%{"model" => "fake-messages-invalid"}, _user_id) do
      {:error, Result.error("bad request", 400, nil)}
    end

    def call_native(_body, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "msg-1",
           "usage" => %{"input_tokens" => 8, "output_tokens" => 3},
           "content" => [%{"type" => "text", "text" => "hi"}]
         },
         nil
       )}
    end

    def stream_native(
          %{"model" => "fake-messages-preflight-failure", "stream" => true},
          _user_id
        ) do
      stream = Stream.map([:request], fn _request -> raise "messages model unavailable" end)
      {:ok, Result.stream(stream, nil)}
    end

    def stream_native(
          %{"model" => "fake-messages-midstream-failure", "stream" => true},
          _user_id
        ) do
      stream =
        Stream.concat(
          [Event.new(%{"type" => "content_block_delta", "delta" => %{"text" => "partial"}})],
          Stream.map([:failure], fn _event -> raise "messages upstream disconnected" end)
        )

      {:ok, Result.stream(stream, nil)}
    end

    def stream_native(%{"stream" => true}, _user_id) do
      {:ok,
       Result.stream(
         [
           Event.new(%{
             "type" => "message_start",
             "message" => %{"usage" => %{"input_tokens" => 8}}
           }),
           Event.new(%{"type" => "message_delta", "usage" => %{"output_tokens" => 3}})
         ],
         nil
       )}
    end

    def stream_error(reason, token), do: Result.error(Exception.message(reason), 400, token)

    def extract_usage(response) do
      usage = response["usage"] || %{}

      LLMProxy.Usage.new(usage["input_tokens"] || 0, usage["output_tokens"] || 0)
    end
  end

  setup do
    TestSupport.checkout_repo()
    Registry.register(FakeMessagesProvider)
    :ok
  end

  test "returns provider-native responses and tracks usage" do
    {:ok, _key, raw_key} = Storage.create_key("messages-user")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-model",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> Plug.Conn.put_req_header("x-request-id", "messages-request-id-123")
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "x-request-id") == ["messages-request-id-123"]
    assert Plug.Conn.get_resp_header(conn, "x-llm-proxy-trace-id") == ["messages-request-id-123"]
    assert Jason.decode!(conn.resp_body)["id"] == "msg-1"

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 8
    assert updated_key.output_tokens == 3
  end

  test "streams provider-native responses" do
    {:ok, _key, raw_key} = Storage.create_key("messages-stream")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-model",
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 200
    assert conn.state == :chunked

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 8
    assert updated_key.output_tokens == 3
  end

  test "returns Anthropic authentication errors before parsing" do
    conn =
      Plug.Test.conn(:post, "/v1/messages", "{invalid-json")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 401

    assert Jason.decode!(conn.resp_body) == %{
             "type" => "error",
             "error" => %{
               "type" => "authentication_error",
               "message" => "Missing API key"
             }
           }
  end

  test "returns HTTP errors for message streams rejected before the first event" do
    {:ok, _key, raw_key} = Storage.create_key("messages-preflight-failure")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-preflight-failure",
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 400
    assert conn.state == :sent

    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) ==
             "messages model unavailable"
  end

  test "renders named message error events after midstream failures" do
    {:ok, _key, raw_key} = Storage.create_key("messages-midstream-failure")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-midstream-failure",
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "partial"
    assert conn.resp_body =~ "event: error"
    assert conn.resp_body =~ "messages upstream disconnected"
  end

  test "rejects invalid message shapes" do
    {:ok, _key, raw_key} = Storage.create_key("messages-invalid-shape")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-model",
        "messages" => [%{"role" => "wat", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 400
    assert get_in(Jason.decode!(conn.resp_body), ["error", "type"]) == "invalid_message"
  end

  test "maps 401 provider errors to authentication errors" do
    {:ok, _key, raw_key} = Storage.create_key("messages-user")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-auth-error",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 401
    assert get_in(Jason.decode!(conn.resp_body), ["error", "type"]) == "authentication_error"
  end

  test "maps 400 provider errors to invalid request errors" do
    {:ok, _key, raw_key} = Storage.create_key("messages-user")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-invalid",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 400
    assert get_in(Jason.decode!(conn.resp_body), ["error", "type"]) == "invalid_request_error"
  end

  test "returns provider-native errors" do
    {:ok, _key, raw_key} = Storage.create_key("messages-user")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-error",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 429
    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) == "provider failed"
  end

  test "returns an Anthropic rate-limit error when concurrent capacity is full" do
    {:ok, key, raw_key} =
      Storage.create_key("messages-concurrent-user", %{
        budget_limits: [Limit.concurrent_requests(1)]
      })

    assert {:ok, lease} = ConcurrencyLimiter.acquire(key)
    on_exit(fn -> ConcurrencyLimiter.release(lease) end)

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "fake-messages-model",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 429
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]

    assert Jason.decode!(conn.resp_body) == %{
             "type" => "error",
             "error" => %{
               "type" => "rate_limit_error",
               "message" => ConcurrencyLimiter.error_message()
             }
           }
  end

  test "returns 404 for unknown routes" do
    {:ok, _key, raw_key} = Storage.create_key("route-user")

    conn =
      Plug.Test.conn(:get, "/missing")
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 404
  end

  test "returns structured 404 errors for unknown models" do
    {:ok, _key, raw_key} = Storage.create_key("messages-user")

    conn =
      TestSupport.json_conn(:post, "/", %{
        "model" => "missing-model",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> MessageEndpoint.call(MessageEndpoint.init([]))

    assert conn.status == 404

    assert Jason.decode!(conn.resp_body) == %{
             "type" => "error",
             "error" => %{
               "type" => "not_found_error",
               "message" => "Model 'missing-model' not found"
             }
           }
  end
end
