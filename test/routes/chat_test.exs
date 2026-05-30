defmodule LLMProxy.Routes.ChatTest do
  use ExUnit.Case

  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Routes.Chat
  alias LLMProxy.Storage
  alias LLMProxy.Stream.Event
  alias LLMProxy.TestSupport

  defmodule FakeChatProvider do
    def name, do: "fake-chat"
    def models, do: ["fake-chat-model", "fake-chat-error"]

    def call(%{"model" => "fake-chat-error"}, _user_id) do
      {:error, Result.error("upstream failed", 502, nil)}
    end

    def call(%{"model" => "fake-chat-model", "messages" => _messages}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "chat-1",
           "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 7}
         },
         nil
       )}
    end

    def stream(_body, _user_id) do
      {:ok,
       Result.stream(
         [
           Event.new(%{"id" => "chat-1", "choices" => [%{"delta" => %{"content" => "hi"}}]}),
           Event.new(
             %{"id" => "chat-1", "choices" => [%{"delta" => %{"content" => " there"}}]},
             usage: LLMProxy.Usage.new(12, 7)
           )
         ],
         nil
       )}
    end

    def extract_usage(response) do
      usage = response["usage"] || %{}

      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)
  end

  defmodule FallbackChatProvider do
    alias LLMProxy.Protocol.OpenAI

    def name, do: "fallback-chat"
    def models, do: ["fallback-chat-model"]

    def call(%{"model" => "fallback-chat-model"}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "fallback-chat-1",
           "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2}
         },
         nil
       )}
    end

    def extract_usage(response), do: OpenAI.extract_usage(response)
    def to_openai_response(response, model), do: Map.put(response, "model", model)
  end

  setup do
    TestSupport.checkout_repo()
    Registry.register(FakeChatProvider)
    Registry.register(FallbackChatProvider)

    on_exit(fn -> Application.delete_env(:llm_proxy, :fallbacks) end)

    :ok
  end

  test "returns chat completions and tracks usage" do
    {:ok, _key, raw_key} = Storage.create_key("chat-user")

    conn =
      TestSupport.json_conn(:post, "/completions", %{
        "model" => "fake-chat-model",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> Chat.call(Chat.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["model"] == "fake-chat-model"

    [message] = Storage.get_messages(%{per_page: 10})
    assert message.route == "chat"
    assert message.user_message == "hello"

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 12
    assert updated_key.output_tokens == 7
  end

  test "streams chat completions" do
    {:ok, _key, raw_key} = Storage.create_key("stream-user")

    conn =
      TestSupport.json_conn(:post, "/completions", %{
        "model" => "fake-chat-model",
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> Chat.call(Chat.init([]))

    assert conn.status == 200
    assert conn.state == :chunked

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 12
    assert updated_key.output_tokens == 7
  end

  test "tracks usage and response model for fallback provider" do
    Application.put_env(:llm_proxy, :fallbacks, %{"fake-chat-error" => ["fallback-chat-model"]})
    {:ok, _key, raw_key} = Storage.create_key("fallback-user")

    conn =
      TestSupport.json_conn(:post, "/completions", %{
        "model" => "fake-chat-error",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> Chat.call(Chat.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["model"] == "fallback-chat-model"

    [updated_key] = Storage.list_keys()
    assert updated_key.input_tokens == 3
    assert updated_key.output_tokens == 2
  end

  test "rejects invalid message shapes" do
    {:ok, _key, raw_key} = Storage.create_key("invalid-message-user")

    conn =
      TestSupport.json_conn(:post, "/completions", %{
        "model" => "fake-chat-model",
        "messages" => [%{"role" => "nope", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> Chat.call(Chat.init([]))

    assert conn.status == 400

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "invalid_message",
               "message" => "Unsupported or malformed message"
             }
           }
  end

  test "returns provider errors" do
    {:ok, _key, raw_key} = Storage.create_key("error-user")

    conn =
      TestSupport.json_conn(:post, "/completions", %{
        "model" => "fake-chat-error",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> Chat.call(Chat.init([]))

    assert conn.status == 502
    assert Jason.decode!(conn.resp_body) == %{"error" => "upstream failed"}
  end

  test "returns 404 for unknown routes" do
    {:ok, _key, raw_key} = Storage.create_key("route-user")

    conn =
      Plug.Test.conn(:get, "/missing")
      |> TestSupport.put_bearer(raw_key)
      |> Chat.call(Chat.init([]))

    assert conn.status == 404
  end

  test "rejects disallowed models" do
    {:ok, _key, raw_key} = Storage.create_key("restricted", %{allowed_models: ["other-model"]})

    conn =
      TestSupport.json_conn(:post, "/completions", %{
        "model" => "fake-chat-model",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> Chat.call(Chat.init([]))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] =~ "not allowed"
  end
end
