defmodule LLMProxy.ProviderUsage.Adapters.Codex do
  @moduledoc "Live OpenAI Codex usage adapter."

  @behaviour LLMProxy.ProviderUsage.Adapter

  alias LLMProxy.Provider.Credential
  alias LLMProxy.Providers.OpenAICodex
  alias LLMProxy.ProviderUsage.{Adapter, HTTP, Result, Source, Window}
  alias ReqLLM.Providers.OpenAICodex, as: ReqLLMOpenAICodex

  @impl true
  def fetch(%Credential{} = credential, %Source{} = source) do
    with {:ok, credential} <- refresh_credential(credential),
         :ok <- validate_credential(credential),
         {:ok, body} <- HTTP.get(source, hd(source.usage_paths), headers(credential)) do
      parse(body)
    end
  end

  @doc false
  @spec parse(map()) :: {:ok, Result.t()} | {:error, :invalid_response | :unsupported}
  def parse(body) when is_map(body) do
    with limits when is_map(limits) <- body["rate_limit"] || body["rate_limits"],
         {:ok, windows} <- windows(limits),
         false <- windows == [] do
      {:ok,
       %Result{
         availability: availability(body, limits, windows),
         windows: windows,
         plan: Adapter.safe_plan(body["plan_type"] || body["planType"])
       }}
    else
      nil -> {:error, :unsupported}
      true -> {:error, :unsupported}
      {:error, _reason} -> {:error, :invalid_response}
      _other -> {:error, :invalid_response}
    end
  end

  def parse(_body), do: {:error, :invalid_response}

  defp refresh_credential(credential) do
    refresh_fun = fn credentials, _opts ->
      timeout = LLMProxy.Config.provider_usage_request_timeout_ms()

      ReqLLMOpenAICodex.refresh_oauth_credentials(credentials,
        oauth_http_options: [
          connect_options: [timeout: timeout],
          receive_timeout: timeout,
          pool_timeout: timeout,
          retry: false,
          redirect: false
        ]
      )
    end

    case OpenAICodex.refresh_token_if_needed(credential, refresh_fun) do
      {:ok, refreshed} -> {:ok, refreshed}
      {:error, _reason} -> {:error, :token_refresh_failed}
    end
  end

  defp validate_credential(%Credential{token: token, expires_at: expires_at}) do
    cond do
      not Adapter.valid_header_value?(token) -> {:error, :authentication_failed}
      expired?(expires_at) -> {:error, :credential_expired}
      true -> :ok
    end
  end

  defp headers(credential) do
    [
      {"authorization", "Bearer #{credential.token}"},
      {"accept", "application/json"},
      {"content-type", "application/json"}
    ]
    |> maybe_account_header(account_id(credential))
  end

  defp account_id(%Credential{account_id: account_id})
       when is_binary(account_id) and account_id != "",
       do: account_id

  defp account_id(%Credential{token: token}) do
    ReqLLMOpenAICodex.account_id_from_token(token)
  rescue
    _error in [ArgumentError, FunctionClauseError] -> nil
  end

  defp maybe_account_header(headers, account_id) do
    if Adapter.valid_header_value?(account_id) do
      headers ++ [{"chatgpt-account-id", account_id}]
    else
      headers
    end
  end

  defp windows(limits) do
    [
      {"Primary", limits["primary_window"] || limits["primary"]},
      {"Secondary", limits["secondary_window"] || limits["secondary"]}
    ]
    |> Adapter.collect(fn {fallback_label, raw} ->
      parse_window(raw, fallback_label)
    end)
  end

  defp parse_window(nil, _fallback_label), do: {:ok, nil}

  defp parse_window(raw, fallback_label) when is_map(raw) do
    with {:ok, used_percent} <-
           Adapter.percent(raw["used_percent"] || raw["usedPercent"], :invalid_percent),
         {:ok, duration_seconds} <- duration_seconds(raw),
         {:ok, resets_at} <- reset_time(raw) do
      {:ok,
       %Window{
         label: window_label(duration_seconds, fallback_label),
         used_percent: used_percent,
         remaining_percent: Adapter.remaining_percent(used_percent),
         resets_at: resets_at,
         duration_seconds: duration_seconds
       }}
    end
  end

  defp parse_window(_raw, _fallback_label), do: {:error, :invalid_window}

  defp duration_seconds(raw) do
    cond do
      positive_number?(raw["limit_window_seconds"]) ->
        {:ok, trunc(raw["limit_window_seconds"])}

      positive_number?(raw["window_minutes"]) ->
        {:ok, trunc(raw["window_minutes"] * 60)}

      positive_number?(raw["windowDurationMins"]) ->
        {:ok, trunc(raw["windowDurationMins"] * 60)}

      true ->
        {:ok, nil}
    end
  end

  defp reset_time(raw) do
    value = raw["reset_at"] || raw["resets_at"] || raw["resetsAt"]
    optional_datetime(value, :second)
  end

  defp optional_datetime(nil, _unit), do: {:ok, nil}

  defp optional_datetime(value, unit) when is_integer(value) do
    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp optional_datetime(value, unit) when is_float(value),
    do: optional_datetime(trunc(value), unit)

  defp optional_datetime(value, unit) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> optional_datetime(integer, unit)
      _other -> iso8601_datetime(value)
    end
  end

  defp optional_datetime(_value, _unit), do: {:error, :invalid_datetime}

  defp iso8601_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp availability(body, limits, windows) do
    cond do
      reached_type?(body["rate_limit_reached_type"] || body["rateLimitReachedType"]) ->
        :unavailable

      spend_control_reached?(body) ->
        :unavailable

      limits["allowed"] == false ->
        :unavailable

      limits["limit_reached"] == true ->
        :unavailable

      Enum.any?(windows, &(&1.used_percent >= 100)) ->
        :unavailable

      Enum.any?(windows, &(&1.used_percent >= 90)) ->
        :limited

      true ->
        :available
    end
  end

  defp reached_type?(value), do: value not in [nil, false]

  defp spend_control_reached?(body) do
    get_in(body, ["spend_control", "reached"]) == true or
      body["spend_control_reached"] == true or body["spendControlReached"] == true
  end

  defp window_label(18_000, _fallback), do: "5 hour"
  defp window_label(604_800, _fallback), do: "Weekly"
  defp window_label(nil, fallback), do: fallback

  defp window_label(seconds, _fallback) when rem(seconds, 604_800) == 0,
    do: duration_label(div(seconds, 604_800), "week")

  defp window_label(seconds, _fallback) when rem(seconds, 3_600) == 0,
    do: duration_label(div(seconds, 3_600), "hour")

  defp window_label(seconds, _fallback) when rem(seconds, 60) == 0,
    do: duration_label(div(seconds, 60), "minute")

  defp window_label(_seconds, fallback), do: fallback

  defp duration_label(1, unit), do: "1 #{unit}"
  defp duration_label(value, unit), do: "#{value} #{unit}s"

  defp positive_number?(value), do: is_number(value) and value > 0

  defp expired?(nil), do: false

  defp expired?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end
end
