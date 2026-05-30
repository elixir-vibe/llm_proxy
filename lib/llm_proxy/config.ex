defmodule LLMProxy.Config do
  @moduledoc false

  def master_key, do: Application.get_env(:llm_proxy, :master_key)

  def valid_master_key?(key) when is_binary(key) do
    case master_key() do
      configured when is_binary(configured) and configured != "" -> key == configured
      _ -> false
    end
  end

  def valid_master_key?(_key), do: false

  def public_url, do: Application.get_env(:llm_proxy, :public_url, "")
  def fallbacks, do: Application.get_env(:llm_proxy, :fallbacks, %{})
  def max_retries, do: Application.get_env(:llm_proxy, :max_retries, 1)
end
