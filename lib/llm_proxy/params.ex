defmodule LLMProxy.Params do
  @moduledoc """
  Small parameter-shaping helpers for optional values and integer coercion at HTTP boundaries.
  """

  def put_if_present(map, _key, nil), do: map
  def put_if_present(map, _key, ""), do: map
  def put_if_present(map, key, value), do: Map.put(map, key, value)

  def put_integer(map, _key, nil), do: map
  def put_integer(map, _key, ""), do: map

  def put_integer(map, key, value) when is_integer(value) do
    Map.put(map, key, value)
  end

  def put_integer(map, key, value) do
    case Integer.parse(value) do
      {int, _} -> Map.put(map, key, int)
      :error -> map
    end
  end
end
