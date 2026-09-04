defmodule LLMProxy.ProviderUsage.Adapters.Codex do
  @moduledoc "Live OpenAI Codex usage adapter."

  @behaviour LLMProxy.ProviderUsage.Adapter

  alias LLMProxy.Provider.Credential
  alias LLMProxy.Providers.OpenAICodex
  alias LLMProxy.ProviderUsage.Adapter
  alias LLMProxy.ProviderUsage.Adapters.Codex.Response
  alias LLMProxy.ProviderUsage.Adapters.Codex.Response.Current
  alias LLMProxy.ProviderUsage.Adapters.Codex.Response.Legacy
  alias LLMProxy.ProviderUsage.Adapters.Codex.Response.ResetCredits
  alias LLMProxy.ProviderUsage.HTTP
  alias LLMProxy.ProviderUsage.Result
  alias LLMProxy.ProviderUsage.Source
  alias LLMProxy.ProviderUsage.Window
  alias ReqLLM.Providers.OpenAICodex, as: ReqLLMOpenAICodex

  @impl true
  def fetch(%Credential{} = credential, %Source{} = source) do
    with {:ok, credential} <- refresh_credential(credential),
         :ok <- validate_credential(credential),
         {:ok, body} <- HTTP.get(source, hd(source.usage_paths), headers(credential)),
         {:ok, result} <- parse(body) do
      {:ok, maybe_attach_reset_credit_details(result, credential, source)}
    end
  end

  @doc false
  @spec parse(String.t()) :: {:ok, Result.t()} | {:error, term()}
  def parse(body), do: Adapter.parse_json(body, Response, &parse_response/1)

  @doc false
  @spec parse_reset_credit_details(String.t()) ::
          {:ok, %{available_count: non_neg_integer(), expires_at: DateTime.t() | nil}}
          | {:error, term()}
  def parse_reset_credit_details(body) when is_binary(body) do
    with {:ok, %ResetCredits{} = response} <- ResetCredits.decode(body),
         {:ok, available_count} <- required_reset_credit_count(response.available_count),
         {:ok, expires_at} <- earliest_available_expiry(response.credits) do
      {:ok, %{available_count: available_count, expires_at: expires_at}}
    else
      {:error, reason} -> {:error, {:invalid_response, reason}}
    end
  end

  def parse_reset_credit_details(_body), do: {:error, :invalid_response}

  defp parse_response(%Current{rate_limit: limits} = response) do
    with :ok <- validate_current_state(response),
         {:ok, plan} <- Adapter.plan(response.plan_type),
         {:ok, reset_credits_available} <-
           reset_credit_count(response.rate_limit_reset_credits),
         {:ok, windows} <-
           windows(
             [
               {"Primary", limits.primary_window},
               {"Secondary", limits.secondary_window}
             ],
             &current_window/2
           ),
         :ok <- require_windows(windows) do
      {:ok,
       %Result{
         availability: current_availability(response, windows),
         windows: windows,
         plan: plan,
         reset_credits_available: reset_credits_available
       }}
    end
  end

  defp parse_response(%Legacy{rate_limits: limits} = response) do
    with :ok <- validate_legacy_state(response),
         {:ok, plan} <- Adapter.plan(response.plan_type),
         {:ok, windows} <-
           windows(
             [{"Primary", limits.primary}, {"Secondary", limits.secondary}],
             &legacy_window/2
           ),
         :ok <- require_windows(windows) do
      {:ok,
       %Result{
         availability: legacy_availability(response, windows),
         windows: windows,
         plan: plan
       }}
    end
  end

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

  defp maybe_attach_reset_credit_details(
         %Result{reset_credits_available: count} = result,
         credential,
         source
       )
       when is_integer(count) and count > 0 do
    with {:ok, path} <- reset_credits_path(source),
         {:ok, body} <- HTTP.get(source, path, reset_credit_headers(credential)),
         {:ok, details} <- parse_reset_credit_details(body) do
      %{
        result
        | reset_credits_available: details.available_count,
          reset_credit_expires_at: details.expires_at
      }
    else
      _error -> result
    end
  end

  defp maybe_attach_reset_credit_details(result, _credential, _source), do: result

  defp reset_credits_path(%Source{usage_paths: [usage_path | _rest]}) do
    if String.ends_with?(usage_path, "/wham/usage") do
      {:ok, String.replace_suffix(usage_path, "/wham/usage", "/wham/rate-limit-reset-credits")}
    else
      {:error, :unsupported}
    end
  end

  defp reset_credits_path(_source), do: {:error, :unsupported}

  defp reset_credit_headers(credential) do
    headers(credential) ++
      [
        {"openai-beta", "codex-1"},
        {"originator", "codex_cli_rs"}
      ]
  end

  defp reset_credit_count(nil), do: {:ok, nil}

  defp reset_credit_count(%ResetCredits{available_count: available_count}) do
    reset_credit_count(available_count)
  end

  defp reset_credit_count(value) when is_integer(value) and value >= 0 and value <= 1_000,
    do: {:ok, value}

  defp reset_credit_count(_value), do: {:error, :invalid_reset_credit_count}

  defp required_reset_credit_count(nil), do: {:error, :missing_reset_credit_count}
  defp required_reset_credit_count(value), do: reset_credit_count(value)

  defp earliest_available_expiry(credits) when is_list(credits) and length(credits) <= 1_000 do
    with {:ok, expiries} <-
           Adapter.collect(credits, fn
             %{status: "available", expires_at: expires_at} -> iso_datetime(expires_at)
             %{status: status} when is_binary(status) -> {:ok, nil}
             _invalid -> {:error, :invalid_reset_credit}
           end) do
      {:ok, Enum.min_by(expiries, &DateTime.to_unix(&1, :microsecond), fn -> nil end)}
    end
  end

  defp earliest_available_expiry(_credits), do: {:error, :invalid_reset_credits}

  defp iso_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_reset_credit_expiry}
    end
  end

  defp iso_datetime(_value), do: {:error, :invalid_reset_credit_expiry}

  defp windows(raw_windows, parser) do
    Adapter.collect(raw_windows, fn
      {_label, nil} -> {:ok, nil}
      {label, raw} -> parser.(raw, label)
    end)
  end

  defp current_window(raw, fallback_label) do
    with {:ok, duration_seconds} <-
           exclusive_duration(raw.limit_window_seconds, raw.window_minutes),
         {:ok, resets_at} <- exclusive_reset(raw.reset_at, raw.resets_at) do
      window(raw.used_percent, duration_seconds, resets_at, fallback_label)
    end
  end

  defp legacy_window(raw, fallback_label) do
    with {:ok, duration_seconds} <- duration_from_minutes(raw.window_duration_mins),
         {:ok, resets_at} <- unix_datetime(raw.resets_at) do
      window(raw.used_percent, duration_seconds, resets_at, fallback_label)
    end
  end

  defp window(used_percent, duration_seconds, resets_at, fallback_label) do
    with {:ok, used_percent} <- Adapter.percent(used_percent, :invalid_percent) do
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

  defp exclusive_duration(nil, nil), do: {:ok, nil}
  defp exclusive_duration(seconds, nil), do: positive_duration(seconds, 1)
  defp exclusive_duration(nil, minutes), do: positive_duration(minutes, 60)
  defp exclusive_duration(_seconds, _minutes), do: {:error, :ambiguous_duration}

  defp duration_from_minutes(nil), do: {:ok, nil}
  defp duration_from_minutes(minutes), do: positive_duration(minutes, 60)

  defp positive_duration(value, multiplier) when is_number(value) and value > 0,
    do: {:ok, trunc(value * multiplier)}

  defp positive_duration(_value, _multiplier), do: {:error, :invalid_duration}

  defp exclusive_reset(nil, nil), do: {:ok, nil}
  defp exclusive_reset(value, nil), do: unix_datetime(value)
  defp exclusive_reset(nil, value), do: unix_datetime(value)
  defp exclusive_reset(_reset_at, _resets_at), do: {:error, :ambiguous_reset_time}

  defp unix_datetime(nil), do: {:ok, nil}

  defp unix_datetime(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> unix_datetime(integer)
      _other -> {:error, :invalid_datetime}
    end
  end

  defp unix_datetime(value) when is_integer(value) and value >= 0 do
    case DateTime.from_unix(value, :second) do
      {:ok, datetime} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp unix_datetime(_value), do: {:error, :invalid_datetime}

  defp validate_current_state(%Current{} = response) do
    with :ok <- validate_reached_type(response.rate_limit_reached_type) do
      validate_optional_boolean(response.spend_control_reached)
    end
  end

  defp validate_legacy_state(%Legacy{} = response) do
    with :ok <- validate_reached_type(response.rate_limit_reached_type) do
      validate_optional_boolean(response.spend_control_reached)
    end
  end

  defp validate_reached_type(nil), do: :ok
  defp validate_reached_type(%{type: "rate_limit_reached"}), do: :ok
  defp validate_reached_type(_value), do: {:error, :invalid_reached_type}

  defp validate_optional_boolean(nil), do: :ok
  defp validate_optional_boolean(value) when is_boolean(value), do: :ok

  defp require_windows([]), do: {:error, :unsupported}
  defp require_windows(_windows), do: :ok

  defp current_availability(response, windows) do
    limits = response.rate_limit

    availability(
      response.rate_limit_reached_type != nil or
        match?(%{reached: true}, response.spend_control) or
        response.spend_control_reached == true or
        limits.allowed == false or limits.limit_reached == true,
      windows
    )
  end

  defp legacy_availability(response, windows) do
    limits = response.rate_limits

    availability(
      response.rate_limit_reached_type != nil or response.spend_control_reached == true or
        limits.allowed == false or limits.limit_reached == true,
      windows
    )
  end

  defp availability(true, _windows), do: :unavailable

  defp availability(false, windows) do
    cond do
      Enum.any?(windows, &(&1.used_percent >= 100)) -> :unavailable
      Enum.any?(windows, &(&1.used_percent >= 90)) -> :limited
      true -> :available
    end
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

  defp expired?(nil), do: false

  defp expired?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end
end
