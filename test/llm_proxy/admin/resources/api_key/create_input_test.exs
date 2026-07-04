defmodule LLMProxy.Admin.Resources.APIKey.CreateInputTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Admin.Resources.APIKey.CreateInput

  test "casts HTTP assigns into a typed command" do
    assert {:ok, %CreateInput{name: "operator", trace_requests: true}} =
             CreateInput.from_assigns(%{"name" => " operator ", "trace_requests" => true})
  end

  test "defaults optional fields" do
    assert {:ok, %CreateInput{name: "api-key", trace_requests: false}} =
             CreateInput.from_assigns(%{})
  end

  test "rejects invalid values" do
    assert {:error, "Name is required"} = CreateInput.from_assigns(%{"name" => " "})

    assert {:error, "trace_requests must be boolean"} =
             CreateInput.from_assigns(%{"trace_requests" => "true"})
  end
end
