defmodule LLMProxy.Integration.Providers.OpenRouterTest do
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox
  alias LLMProxy.Providers.{OpenRouter, Result}
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo.SQLite
  alias LLMProxy.TokenPool.Server, as: TokenPool

  @moduletag :integration
  @moduletag timeout: 30_000

  @model "openai/gpt-4o-mini"

  @api_key :llm_proxy
           |> Application.compile_env(:providers, %{})
           |> get_in(["openrouter", :api_keys])
           |> to_string()
           |> String.split(",", trim: true)
           |> List.first()

  if is_nil(@api_key) do
    @moduletag :skip
  end

  setup do
    :ok = Sandbox.checkout(SQLite)
    Sandbox.mode(SQLite, {:shared, self()})

    {:ok, _token} = Storage.add_token("openrouter", "api-key", @api_key)
    TokenPool.clear_rate_limits()

    :ok
  end

  describe "non-streaming" do
    test "call returns choices with message content" do
      body = %{
        "model" => @model,
        "messages" => [%{"role" => "user", "content" => "Say hi"}],
        "max_tokens" => 20
      }

      assert {:ok, %Result{response: response}} = OpenRouter.call(body, "test-user")
      assert is_map(response)
      assert [choice | _] = response["choices"]
      assert choice["message"]["content"]
      assert is_binary(choice["message"]["content"])
    end
  end

  describe "streaming" do
    test "stream returns events with content deltas and usage" do
      body = %{
        "model" => @model,
        "messages" => [%{"role" => "user", "content" => "Say hi"}],
        "max_tokens" => 20,
        "stream_options" => %{"include_usage" => true}
      }

      assert {:ok, %Result{stream: stream}} = OpenRouter.stream(body, "test-user")

      events = Enum.to_list(stream)
      assert events != []

      has_content =
        Enum.any?(events, fn event ->
          case event.data do
            %{"choices" => [%{"delta" => %{"content" => c}} | _]} when is_binary(c) and c != "" ->
              true

            _ ->
              false
          end
        end)

      assert has_content, "Expected at least one event with content delta"

      has_usage =
        Enum.any?(events, fn event ->
          Map.has_key?(event, :usage)
        end)

      assert has_usage, "Expected at least one event with usage info"
    end
  end
end
