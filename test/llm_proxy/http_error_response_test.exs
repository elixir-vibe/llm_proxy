defmodule LLMProxy.HTTP.ErrorResponseTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias LLMProxy.HTTP.ErrorResponse

  test "renders one normalized OpenAI error object and drops internal fields" do
    conn =
      conn(:post, "/v1/responses")
      |> ErrorResponse.send_openai(502, %{
        "message" => ~s(Stream failed: {:remote, 1000, ""}),
        "type" => "upstream_error",
        "code" => "upstream_error",
        "headers" => %{"authorization" => "Bearer secret"},
        "details" => %{"request" => "private"}
      })

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "message" => "Upstream provider request failed",
               "type" => "upstream_error",
               "code" => "upstream_error",
               "status" => 502
             }
           }

    refute conn.resp_body =~ "secret"
    refute conn.resp_body =~ "{:remote"
    refute conn.resp_body =~ "details"
  end

  test "forwards safe structured OpenAI error fields" do
    conn =
      conn(:post, "/v1/chat/completions")
      |> ErrorResponse.send_openai(400, %{
        "message" => "Invalid response schema",
        "code" => "invalid_json_schema",
        "param" => "response_format"
      })

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "message" => "Invalid response schema",
               "type" => "invalid_json_schema",
               "code" => "invalid_json_schema",
               "status" => 400,
               "param" => "response_format"
             }
           }
  end

  test "shared errors use the Anthropic envelope on the Messages path" do
    conn =
      conn(:post, "/v1/messages")
      |> ErrorResponse.send(401, "authentication_error", "Missing API key")

    assert Jason.decode!(conn.resp_body) == %{
             "type" => "error",
             "error" => %{
               "type" => "authentication_error",
               "message" => "Missing API key"
             }
           }
  end
end
