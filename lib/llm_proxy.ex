defmodule LLMProxy do
  @moduledoc """
  OpenAI-compatible proxy for LLM APIs with usage tracking and per-user quotas.
  """

  @doc """
  Calls the proxy in-process using ReqLLM messages or a plain prompt.

  Pass either `:actor` with `%LLMProxy.Actor{}` or `:api_key` with an existing
  LLMProxy API key schema/map so quota and usage accounting can run.
  """
  defdelegate chat(messages, opts \\ []), to: LLMProxy.Provider
end
