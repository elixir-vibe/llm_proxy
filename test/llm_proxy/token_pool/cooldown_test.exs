defmodule LLMProxy.TokenPool.CooldownTest do
  use ExUnit.Case, async: true

  alias LLMProxy.TokenPool.Cooldown

  test "derives a fixed non-reversible model key" do
    key = Cooldown.model_key!("provider/model")

    assert byte_size(key) == 64
    assert key == Cooldown.model_key!("provider/model")
    refute key =~ "provider/model"
  end

  test "rejects malformed model identities" do
    for model <- [nil, "", " model", "model ", "bad\nmodel", :model] do
      assert_raise ArgumentError, fn -> Cooldown.model_key!(model) end
    end

    assert_raise ArgumentError, fn -> Cooldown.model_key!(String.duplicate("m", 513)) end
  end

  test "accepts only bounded positive cooldown durations" do
    max_duration = :timer.hours(24) * 31

    assert Cooldown.duration!(1) == 1
    assert Cooldown.duration!(max_duration) == max_duration
    refute Cooldown.valid_duration?(0)
    refute Cooldown.valid_duration?(max_duration + 1)
    assert_raise ArgumentError, fn -> Cooldown.duration!(0) end
  end
end
