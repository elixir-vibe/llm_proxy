defmodule LLMProxy.Providers.RateLimit do
  @moduledoc false

  alias LLMProxy.Config
  alias LLMProxy.Providers.Result
  alias LLMProxy.TokenPool.Cooldown
  alias LLMProxy.TokenPool.Server, as: TokenPool

  @spec record(Result.t()) :: Result.t()
  def record(%Result{status: 429, token: token, rate_limit_kind: kind} = result)
      when not is_nil(token) and kind in [:throttle, :quota] do
    provider = result.provider_name || token.provider

    duration =
      result.retry_after_ms ||
        case result.rate_limit_kind do
          :quota -> Config.quota_cooldown_ms(provider)
          :throttle -> Config.rate_limit_cooldown_ms(provider)
        end

    if duration > 0 do
      if result.rate_limit_scope == :account or is_nil(result.model) do
        TokenPool.mark_rate_limited(token, duration)
      else
        TokenPool.mark_rate_limited(token, result.model, duration)
      end
    end

    %{result | retry_after_ms: duration}
  end

  def record(%Result{} = result), do: result

  @doc false
  def retry_after_ms(headers, now_ms \\ System.system_time(:millisecond)) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "retry-after", do: List.first(List.wrap(value))
    end)
    |> parse_retry_after(now_ms)
    |> valid_delay()
  end

  defp parse_retry_after(nil, _now_ms), do: nil

  defp parse_retry_after(value, now_ms) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> http_date_delay(value, now_ms)
    end
  end

  defp parse_retry_after(_value, _now_ms), do: nil

  defp http_date_delay(value, now_ms) do
    case Req.Utils.parse_http_date(value) do
      {:ok, date} -> max(DateTime.to_unix(date, :millisecond) - now_ms, 0)
      {:error, _} -> nil
    end
  end

  defp valid_delay(0), do: 0
  defp valid_delay(delay), do: if(Cooldown.valid_duration?(delay), do: delay)
end
