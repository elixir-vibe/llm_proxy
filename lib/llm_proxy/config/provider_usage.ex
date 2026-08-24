defmodule LLMProxy.Config.ProviderUsage do
  @moduledoc false

  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) when is_binary(path) do
    String.valid?(path) and byte_size(path) <= 256 and String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.contains?(path, ["?", "#", "\\"]) and valid_path_bytes?(path)
  end

  def valid_path?(_path), do: false

  defp valid_path_bytes?(path) do
    path
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 > 0x20 and &1 != 0x7F))
  end
end
