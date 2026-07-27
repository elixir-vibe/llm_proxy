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

  test "forwards only normalized provider error fields" do
    result =
      Result.error("provider failed", 400, nil,
        provider_body: %{
          "error" => %{
            "message" => "Invalid schema",
            "code" => "invalid_json_schema",
            "param" => "response_format",
            "headers" => %{"authorization" => "Bearer secret"},
            "request" => %{"tool_arguments" => "private"}
          }
        }
      )

    assert Result.client_error(result) == %{
             "message" => "Invalid schema",
             "type" => "invalid_json_schema",
             "code" => "invalid_json_schema",
             "status" => 400,
             "param" => "response_format"
           }
  end

  test "falls back when provider error fields contain internal terms" do
    result =
      Result.error("provider failed", 502, nil,
        provider_body: %{"error" => %{"message" => {:remote, 1000, ""}, "code" => %{}}}
      )

    assert Result.client_error(result) == %{
             "message" => "provider failed",
             "type" => "upstream_error",
             "code" => "upstream_error",
             "status" => 502
           }
  end

  test "attaches routing attempt metadata" do
    assert {:ok, %Result{provider: String, model: "model"}} =
             Result.response(%{}, nil)
             |> then(&Result.with_attempt({:ok, &1}, String, "model"))
  end
end
