defmodule LLMProxy.ParamsTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Params

  test "put_if_present/3 skips nil and empty values" do
    assert Params.put_if_present(%{}, :key, nil) == %{}
    assert Params.put_if_present(%{}, :key, "") == %{}
    assert Params.put_if_present(%{}, :key, "value") == %{key: "value"}
  end

  test "put_integer/3 parses integers and ignores invalid values" do
    assert Params.put_integer(%{}, :offset, nil) == %{}
    assert Params.put_integer(%{}, :offset, "") == %{}
    assert Params.put_integer(%{}, :offset, "12") == %{offset: 12}
    assert Params.put_integer(%{}, :offset, 12) == %{offset: 12}
    assert Params.put_integer(%{}, :offset, "nope") == %{}
  end
end
