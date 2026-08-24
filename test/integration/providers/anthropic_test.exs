defmodule LLMProxy.Integration.Providers.AnthropicTest do
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox
  alias LLMProxy.Providers.{Anthropic, Result}
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo.SQLite
  alias LLMProxy.Stream.Event
  alias LLMProxy.TokenPool.Server, as: TokenPool

  @moduletag :integration
  @moduletag timeout: 30_000

  @model "claude-3-5-haiku-20241022"

  @api_key :llm_proxy
           |> Application.compile_env(:providers, %{})
           |> get_in(["anthropic", :api_keys])
           |> to_string()
           |> String.split(",", trim: true)
           |> List.first()

  if is_nil(@api_key) do
    @moduletag :skip
  end

  setup do
    :ok = Sandbox.checkout(SQLite)
    Sandbox.mode(SQLite, {:shared, self()})

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

      assert {:ok, %Result{response: response}} = Anthropic.call(body, "test-user")
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

      assert {:ok, %Result{stream: stream}} = Anthropic.stream(body, "test-user")

      events = Enum.to_list(stream)
      assert events != []

      has_message_start =
        Enum.any?(events, fn event ->
          match?(%Event{data: %{"type" => "message_start"}}, event)
        end)

      assert has_message_start, "Expected a message_start event"

      has_content_delta =
        Enum.any?(events, fn event ->
          match?(%Event{data: %{"type" => "content_block_delta"}}, event)
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

      assert {:ok, %Result{response: response}} = Anthropic.call_native(body, "test-user")
      assert response["type"] == "message"
      assert [block | _] = response["content"]
      assert block["type"] == "text"
      assert is_binary(block["text"])
    end
  end
end
