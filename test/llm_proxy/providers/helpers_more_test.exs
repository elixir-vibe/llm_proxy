defmodule LLMProxy.Providers.HelpersMoreTest do
  use ExUnit.Case

  alias LLMProxy.Usage

  alias LLMProxy.Providers.{Helpers, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    :ok
  end

  test "pick_token/2 returns a structured error when no tokens are available" do
    assert Helpers.pick_token("missing", "user-1") ==
             {:error, Result.error("No available tokens: no_tokens", 503, nil)}
  end

  test "handle_error_response/3 marks rate-limited tokens" do
    {:ok, token} = Storage.add_token("openai", "api-key", "token")

    assert {:error, %Result{status: 429, token: ^token}} =
             Helpers.handle_error_response(token, 429, %{"error" => "slow down"})
  end

  test "handle_exception/1 wraps exceptions" do
    assert {:error, %Result{status: 502, error: "boom"}} =
             Helpers.handle_exception(%RuntimeError{message: "boom"})
  end

  test "openai_stream_event_from_map/1 extracts usage" do
    event =
      Helpers.openai_stream_event_from_map(%{
        "usage" => %{
          "prompt_tokens" => 3,
          "completion_tokens" => 2,
          "prompt_tokens_details" => %{"cached_tokens" => 1}
        }
      })

    assert event.usage ==
             Usage.new(3, 2, 1, 0)
  end

  test "parse_sse_events/1 parses multi-event chunks" do
    events =
      ["data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"]
      |> Helpers.parse_sse_events()
      |> Enum.to_list()

    assert Enum.map(events, & &1.data) == ["{\"a\":1}", "{\"b\":2}"]
  end
end
