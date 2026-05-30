defmodule LLMProxy.Providers.CallerTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Caller, Result}
  alias LLMProxy.Stream.Event

  defmodule SuccessProvider do
    def name, do: "success"
    def call(_body, _user_id), do: {:ok, Result.response(%{"ok" => true}, nil)}
    def stream(_body, _user_id), do: {:ok, Result.stream([], nil)}
  end

  defmodule FailProvider do
    def name, do: "fail"
    def call(_body, _user_id), do: {:error, Result.error("server error", 500, nil)}
    def stream(_body, _user_id), do: {:error, Result.error("server error", 500, nil)}
  end

  defmodule RateLimitedProvider do
    def name, do: "limited"
    def call(_body, _user_id), do: {:error, Result.error("rate limited", 429, nil)}
    def stream(_body, _user_id), do: {:error, Result.error("rate limited", 429, nil)}
  end

  defmodule AuthErrorProvider do
    def name, do: "auth_fail"
    def call(_body, _user_id), do: {:error, Result.error("unauthorized", 401, nil)}
    def stream(_body, _user_id), do: {:error, Result.error("unauthorized", 401, nil)}
  end

  defmodule NativeAnthropicProvider do
    def name, do: "native-anthropic"
    def native_protocol, do: :anthropic

    def call(
          %{"max_tokens" => 4096, "messages" => [%{"role" => "user", "content" => "hello"}]},
          _user_id
        ),
        do: {:ok, Result.response(%{"ok" => "anthropic"}, nil)}

    def stream(%{"max_tokens" => 4096, "stream" => true}, _user_id),
      do: {:ok, Result.stream([], nil)}
  end

  defmodule FallbackProvider do
    def name, do: "fallback"
    def models, do: ["fallback-model"]

    def call(%{"model" => "fallback-model"}, _user_id),
      do: {:ok, Result.response(%{"ok" => "fallback"}, nil)}

    def stream(%{"model" => "fallback-model"}, _user_id),
      do: {:ok, Result.stream([Event.new(%{"ok" => true})], nil)}
  end

  setup do
    LLMProxy.Providers.Registry.register(FallbackProvider)
    on_exit(fn -> Application.delete_env(:llm_proxy, :fallbacks) end)
    :ok
  end

  describe "call/4 with no fallbacks" do
    test "returns success on first try" do
      assert {:ok, %Result{response: %{"ok" => true}, provider: SuccessProvider, model: "m"}} =
               Caller.call(SuccessProvider, request("m"), "user", "m")
    end

    test "returns error when provider fails with non-retryable error" do
      assert {:error, %Result{status: 401}} =
               Caller.call(AuthErrorProvider, request("m"), "user", "m")
    end

    test "returns error when provider fails with retryable error but no fallbacks" do
      assert {:error, %Result{status: 500}} =
               Caller.call(FailProvider, request("m"), "user", "m")
    end
  end

  describe "call/4 protocol conversion" do
    test "converts OpenAI chat bodies to provider-native request format" do
      assert {:ok, %Result{response: %{"ok" => "anthropic"}, provider: NativeAnthropicProvider}} =
               Caller.call(
                 NativeAnthropicProvider,
                 request("claude"),
                 "user",
                 "claude"
               )
    end
  end

  describe "call/4 with fallbacks" do
    test "tries configured fallback providers on retryable errors" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})

      assert {:ok,
              %{
                response: %{"ok" => "fallback"},
                provider: FallbackProvider,
                model: "fallback-model"
              }} =
               Caller.call(FailProvider, request("m"), "user", "m")
    end

    test "tries fallbacks on rate limits" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})

      assert {:ok,
              %{
                response: %{"ok" => "fallback"},
                provider: FallbackProvider,
                model: "fallback-model"
              }} =
               Caller.call(RateLimitedProvider, request("m"), "user", "m")
    end
  end

  describe "stream/4 with no fallbacks" do
    test "returns success on first try" do
      assert {:ok, %Result{stream: [], provider: SuccessProvider, model: "m"}} =
               Caller.stream(SuccessProvider, request("m"), "user", "m")
    end

    test "returns error on non-retryable error" do
      assert {:error, %Result{status: 401}} =
               Caller.stream(AuthErrorProvider, request("m"), "user", "m")
    end
  end

  describe "stream/4 with fallbacks" do
    test "tries configured fallback streams on retryable errors" do
      Application.put_env(:llm_proxy, :fallbacks, %{"m" => ["fallback-model"]})

      assert {:ok,
              %{
                stream: [%Event{data: %{"ok" => true}}],
                provider: FallbackProvider,
                model: "fallback-model"
              }} =
               Caller.stream(FailProvider, request("m"), "user", "m")
    end
  end

  defp request(model) do
    {:ok, request} =
      Request.parse(:openai_chat, %{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "max_tokens" => 4096
      })

    request
  end
end
