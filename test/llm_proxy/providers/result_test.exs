defmodule LLMProxy.Providers.ResultTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.Result

  test "constructs tagged response results" do
    token = %{id: 1}

    assert %Result{kind: :response, response: %{"ok" => true}, token: ^token} =
             Result.response(%{"ok" => true}, token)
  end

  test "constructs tagged stream results" do
    stream = [1, 2]

    assert %Result{kind: :stream, stream: ^stream, token: nil} = Result.stream(stream, nil)
  end

  test "constructs tagged error results with retry metadata" do
    assert %Result{kind: :error, error: "rate limited", status: 429, retry_after_ms: 100} =
             Result.error("rate limited", 429, nil, retry_after_ms: 100)
  end

  test "constructs unavailable token errors" do
    assert {:error, %Result{kind: :error, error: "No available tokens: no_tokens", status: 503}} =
             Result.unavailable_tokens(:no_tokens)
  end

  test "attaches routing attempt metadata" do
    assert {:ok, %Result{provider: String, model: "model"}} =
             Result.response(%{}, nil)
             |> then(&Result.with_attempt({:ok, &1}, String, "model"))
  end
end
