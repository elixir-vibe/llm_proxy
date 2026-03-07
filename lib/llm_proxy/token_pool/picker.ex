defmodule LlmProxy.TokenPool.Picker do
  @moduledoc """
  Deterministic user→token pinning via FNV-1a hash for cache affinity.
  """

  import Bitwise

  def pick_index(_user_id, pool_size) when pool_size <= 1, do: 0

  def pick_index(user_id, pool_size) do
    rem(fnv1a(user_id), pool_size)
  end

  defp fnv1a(str) do
    str
    |> :binary.bin_to_list()
    |> Enum.reduce(0x811C9DC5, fn byte, hash ->
      bxor(hash, byte)
      |> Kernel.*(0x01000193)
      |> band(0xFFFFFFFF)
    end)
  end
end
