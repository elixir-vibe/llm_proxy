defmodule LlmProxyTest do
  use ExUnit.Case
  doctest LlmProxy

  test "greets the world" do
    assert LlmProxy.hello() == :world
  end
end
