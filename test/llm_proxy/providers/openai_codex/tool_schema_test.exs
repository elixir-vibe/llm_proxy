defmodule LLMProxy.Providers.OpenAICodex.ToolSchemaTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.OpenAICodex.ToolSchema

  test "strictifies wrapped OpenAI wire function tools through a typed boundary" do
    [tool] =
      ToolSchema.strictify([
        %{
          "type" => "function",
          "function" => %{
            "name" => "fetch",
            "description" => "Fetch a URL",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "url" => %{"type" => "string"},
                "headers" => %{
                  "type" => "object",
                  "properties" => %{"accept" => %{"type" => "string"}}
                }
              },
              "required" => ["url"]
            }
          }
        }
      ])

    params = tool["function"]["parameters"]
    assert params["additionalProperties"] == false
    assert Enum.sort(params["required"]) == ["headers", "url"]

    headers = params["properties"]["headers"]
    assert headers["additionalProperties"] == false
    assert headers["required"] == ["accept"]
  end

  test "strictifies flattened OpenAI function tools through the same typed boundary" do
    [tool] =
      ToolSchema.strictify([
        %{
          "type" => "function",
          "name" => "fetch",
          "description" => "Fetch a URL",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "url" => %{"type" => "string"},
              "headers" => %{
                "type" => "object",
                "properties" => %{"accept" => %{"type" => "string"}}
              }
            },
            "required" => ["url"]
          }
        }
      ])

    params = tool["parameters"]
    assert tool["name"] == "fetch"
    assert params["additionalProperties"] == false
    assert Enum.sort(params["required"]) == ["headers", "url"]
    assert params["properties"]["headers"]["additionalProperties"] == false
  end
end
