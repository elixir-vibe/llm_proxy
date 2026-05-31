defmodule LLMProxy.TokenPool.RateLimit do
  @moduledoc false

  require Logger

  alias LLMProxy.TokenPool.Server, as: TokenPool

  def mark_rate_limited(token) do
    TokenPool.mark_rate_limited(token)
    Logger.warning("Token #{token.id} marked as rate-limited")
  end
end
