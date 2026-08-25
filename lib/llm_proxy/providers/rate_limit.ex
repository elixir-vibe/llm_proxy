defmodule LLMProxy.Providers.RateLimit do
  @moduledoc false

  alias LLMProxy.Providers.Result
  alias LLMProxy.TokenPool.Server, as: TokenPool

  @spec record(Result.t()) :: term()
  def record(%Result{status: 429, token: token, model: model})
      when not is_nil(token) and is_binary(model) do
    TokenPool.mark_rate_limited(token, model, LLMProxy.Config.token_cooldown_ms())
  end

  def record(%Result{status: 429, token: token}) when not is_nil(token),
    do: TokenPool.mark_rate_limited(token)

  def record(%Result{}), do: :ok
end
