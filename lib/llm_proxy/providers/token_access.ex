defmodule LLMProxy.Providers.TokenAccess do
  @moduledoc false

  alias LLMProxy.Providers.Result
  alias LLMProxy.TokenPool.Server, as: TokenPool

  def pick_token(provider_name, user_id) do
    case TokenPool.pick_token(provider_name, user_id) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, Result.error("No available tokens: #{reason}", 503, nil)}
    end
  end
end
