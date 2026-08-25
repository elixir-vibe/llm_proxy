defmodule LLMProxy.Providers.ResultTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.Result

  defmodule LegacyStreamProvider do
    def name, do: "legacy-stream"
    def stream_error(_reason, token), do: Result.error("legacy failure", 400, token)
  end

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
    assert %Result{
             kind: :error,
             error: "rate limited",
             status: 429,
             retry_after_ms: 100,
             replay_safety: :safe
           } =
             Result.error("rate limited", 429, nil, retry_after_ms: 100)
  end

  test "classifies server errors as uncertain unless a provider proves safety" do
    assert Result.error("server error", 500, nil).replay_safety == :uncertain

    assert Result.error("connect failed", 502, nil, replay_safety: :safe).replay_safety ==
             :safe

    assert Result.error("bad request", 400, nil).replay_safety == :forbidden
  end

  test "constructs unavailable token errors without exposing pool internals" do
    assert {:error,
            %Result{
              kind: :error,
              error: "No available provider credentials",
              status: 503,
              replay_safety: :safe
            } = result} = Result.unavailable_tokens({:no_tokens, :private_pool})

    assert Result.client_error(result)["code"] == "service_unavailable"
    refute Jason.encode!(Result.client_error(result)) =~ "private_pool"
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

  test "supports legacy two-argument stream error callbacks" do
    token = %{id: 1}

    assert %Result{status: 400, token: ^token, model: "model-a"} =
             Result.stream_failure(LegacyStreamProvider, "model-a", token, :failure)
  end

  test "attaches routing attempt metadata" do
    assert {:ok, %Result{provider: String, model: "model"}} =
             Result.response(%{}, nil)
             |> then(&Result.with_attempt({:ok, &1}, String, "model"))
  end
end
