defmodule LLMProxy.Storage.JSONTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Storage.JSON

  test "casts and dumps JSON lists and maps" do
    assert JSON.cast(["gpt-4o"]) == {:ok, ["gpt-4o"]}
    assert JSON.cast(%{"trace_id" => "req-1"}) == {:ok, %{"trace_id" => "req-1"}}
    assert JSON.cast(~s({"trace_id":"req-1"})) == {:ok, %{"trace_id" => "req-1"}}

    assert JSON.dump([%{"metric" => "cost_usd"}]) == {:ok, ~s([{"metric":"cost_usd"}])}
    assert JSON.load(~s(["gpt-4o"])) == {:ok, ["gpt-4o"]}
  end
end
