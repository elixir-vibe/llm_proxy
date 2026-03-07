defmodule LLMProxy.Integration.AnthropicTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox
  alias LLMProxy.Providers.Anthropic
  alias LLMProxy.Repo
  alias LLMProxy.Router
  alias LLMProxy.Storage
  alias LLMProxy.TokenPool.Server, as: TokenPool

  @moduletag :integration
  @moduletag timeout: 30_000

  @model "claude-3-5-haiku-20241022"

  @api_key Application.compile_env(:llm_proxy, :anthropic_api_keys, "")
          |> String.split(",", trim: true)
          |> List.first()

  if is_nil(@api_key) do
    @moduletag :skip
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    {:ok, _token} = Storage.add_token("anthropic", "api-key", @api_key)
    TokenPool.clear_rate_limits()

    :ok
  end

  describe "non-streaming via provider" do
    test "call returns content blocks" do
      body = %{
        "model" => @model,
        "messages" => [%{"role" => "user", "content" => "Say hi"}],
        "max_tokens" => 20
      }

      assert {:ok, %{response: response}} = Anthropic.call(body, "test-user")
      assert is_map(response)
      assert [block | _] = response["content"]
      assert block["type"] == "text"
      assert is_binary(block["text"])
    end
  end

  describe "streaming via provider" do
    test "stream returns message_start and content_block_delta events" do
      body = %{
        "model" => @model,
        "messages" => [%{"role" => "user", "content" => "Say hi"}],
        "max_tokens" => 20
      }

      assert {:ok, %{stream: stream}} = Anthropic.stream(body, "test-user")

      events = Enum.to_list(stream)
      assert events != []

      has_message_start =
        Enum.any?(events, fn event ->
          match?(%{data: %{"type" => "message_start"}}, event)
        end)

      assert has_message_start, "Expected a message_start event"

      has_content_delta =
        Enum.any?(events, fn event ->
          match?(%{data: %{"type" => "content_block_delta"}}, event)
        end)

      assert has_content_delta, "Expected at least one content_block_delta event"
    end
  end

  describe "call_native" do
    test "sends native Anthropic format and returns response" do
      body = %{
        "model" => @model,
        "messages" => [%{"role" => "user", "content" => "Say hi"}],
        "max_tokens" => 20
      }

      assert {:ok, %{response: response}} = Anthropic.call_native(body, "test-user")
      assert response["type"] == "message"
      assert [block | _] = response["content"]
      assert block["type"] == "text"
      assert is_binary(block["text"])
    end
  end

  describe "end-to-end via router /v1/chat/completions" do
    test "OpenAI format request returns OpenAI format response" do
      master_key = Application.get_env(:llm_proxy, :master_key)

      body =
        Jason.encode!(%{
          "model" => @model,
          "messages" => [%{"role" => "user", "content" => "Say hi"}],
          "max_tokens" => 20
        })

      conn =
        conn(:post, "/v1/chat/completions", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{master_key}")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["object"] == "chat.completion"
      assert [choice | _] = response["choices"]
      assert choice["message"]["role"] == "assistant"
      assert is_binary(choice["message"]["content"])
      assert response["usage"]["prompt_tokens"] > 0
    end
  end

  describe "end-to-end via router /v1/messages" do
    test "native Anthropic format returns Anthropic format response" do
      master_key = Application.get_env(:llm_proxy, :master_key)

      body =
        Jason.encode!(%{
          "model" => @model,
          "messages" => [%{"role" => "user", "content" => "Say hi"}],
          "max_tokens" => 20
        })

      conn =
        conn(:post, "/v1/messages", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{master_key}")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["type"] == "message"
      assert response["role"] == "assistant"
      assert [block | _] = response["content"]
      assert block["type"] == "text"
      assert is_binary(block["text"])
    end
  end
end
