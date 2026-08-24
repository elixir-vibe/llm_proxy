defmodule LLMProxy.Config.ProviderUsage do
  @moduledoc false

  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) when is_binary(path) do
    byte_size(path) <= 256 and String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.contains?(path, ["?", "#", "\\", "\r", "\n"])
  end

  def valid_path?(_path), do: false
end
