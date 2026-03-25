defmodule LLMProxy.Providers.CallerTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.Caller

  defmodule SuccessProvider do
    def name, do: "success"
    def call(_body, _user_id), do: {:ok, %{response: %{"ok" => true}, token: nil}}
    def stream(_body, _user_id), do: {:ok, %{stream: [], token: nil}}
  end

  defmodule FailProvider do
    def name, do: "fail"
    def call(_body, _user_id), do: {:error, %{error: "server error", status: 500, token: nil}}
    def stream(_body, _user_id), do: {:error, %{error: "server error", status: 500, token: nil}}
  end

  defmodule RateLimitedProvider do
    def name, do: "limited"
    def call(_body, _user_id), do: {:error, %{error: "rate limited", status: 429, token: nil}}
    def stream(_body, _user_id), do: {:error, %{error: "rate limited", status: 429, token: nil}}
  end

  defmodule AuthErrorProvider do
    def name, do: "auth_fail"
    def call(_body, _user_id), do: {:error, %{error: "unauthorized", status: 401, token: nil}}
    def stream(_body, _user_id), do: {:error, %{error: "unauthorized", status: 401, token: nil}}
  end

  describe "call/4 with no fallbacks" do
    test "returns success on first try" do
      assert {:ok, %{response: %{"ok" => true}}} =
               Caller.call(SuccessProvider, %{"model" => "m"}, "user", "m")
    end

    test "returns error when provider fails with non-retryable error" do
      assert {:error, %{status: 401}} =
               Caller.call(AuthErrorProvider, %{"model" => "m"}, "user", "m")
    end

    test "returns error when provider fails with retryable error but no fallbacks" do
      assert {:error, %{status: 500}} =
               Caller.call(FailProvider, %{"model" => "m"}, "user", "m")
    end
  end

  describe "stream/4 with no fallbacks" do
    test "returns success on first try" do
      assert {:ok, %{stream: []}} =
               Caller.stream(SuccessProvider, %{"model" => "m"}, "user", "m")
    end

    test "returns error on non-retryable error" do
      assert {:error, %{status: 401}} =
               Caller.stream(AuthErrorProvider, %{"model" => "m"}, "user", "m")
    end
  end
end
