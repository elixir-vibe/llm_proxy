defmodule LLMProxy.Config do
  @moduledoc false
  def master_key, do: Application.get_env(:llm_proxy, :master_key, "")
  def public_url, do: Application.get_env(:llm_proxy, :public_url, "")
  def exa_api_key, do: Application.get_env(:llm_proxy, :exa_api_key, "")
  def context7_api_key, do: Application.get_env(:llm_proxy, :context7_api_key, "")
  def fallbacks, do: Application.get_env(:llm_proxy, :fallbacks, %{})
  def max_retries, do: Application.get_env(:llm_proxy, :max_retries, 1)
end
