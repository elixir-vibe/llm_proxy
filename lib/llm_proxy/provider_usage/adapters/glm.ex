defmodule LLMProxy.ProviderUsage.Adapters.GLM do
  @moduledoc "Live Z.AI GLM Coding Plan usage adapter."

  @behaviour LLMProxy.ProviderUsage.Adapter

  alias LLMProxy.Provider.Credential
  alias LLMProxy.ProviderUsage.Adapter
  alias LLMProxy.ProviderUsage.Adapters.GLM.Response
  alias LLMProxy.ProviderUsage.Adapters.GLM.Response.Authentication
  alias LLMProxy.ProviderUsage.Adapters.GLM.Response.Data
  alias LLMProxy.ProviderUsage.Adapters.GLM.Response.Envelope
  alias LLMProxy.ProviderUsage.Adapters.GLM.Response.Failure
  alias LLMProxy.ProviderUsage.Adapters.GLM.Response.Limit
  alias LLMProxy.ProviderUsage.HTTP
  alias LLMProxy.ProviderUsage.Result
  alias LLMProxy.ProviderUsage.Source
  alias LLMProxy.ProviderUsage.Window

  @supported_limit_types ~w(TOKENS_LIMIT CREDIT_LIMIT TIME_LIMIT)

  @impl true
  def fetch(%Credential{} = credential, %Source{} = source) do
    with :ok <- validate_credential(credential) do
      fetch_paths(source.usage_paths, credential, source)
    end
  end

  @doc false
  @spec parse(String.t()) :: {:ok, Result.t()} | {:error, term()}
  def parse(body) when is_binary(body) do
    case Response.decode(body) do
      {:ok, response} -> parse_response(response)
      {:error, reason} -> {:error, {:invalid_response, reason}}
    end
  end

  def parse(_body), do: {:error, :invalid_response}

  defp parse_response(%Authentication{code: code}) when code in [401, 403],
    do: {:error, :authentication_failed}

  defp parse_response(%Authentication{}), do: {:error, :invalid_response}
  defp parse_response(%Failure{success: false}), do: {:error, :unsupported}
  defp parse_response(%Failure{}), do: {:error, :invalid_response}

  defp parse_response(%Envelope{code: code}) when code in [401, 403],
    do: {:error, :authentication_failed}

  defp parse_response(%Envelope{success: false}), do: {:error, :unsupported}
  defp parse_response(%Envelope{data: data}), do: parse_data(data)
  defp parse_response(%Data{} = data), do: parse_data(data)

  defp parse_data(%Data{limits: limits} = data) do
    with {:ok, plan} <- Adapter.plan(data.level),
         {:ok, windows} <- Adapter.collect(limits, &parse_window/1),
         false <- windows == [] do
      {:ok,
       %Result{
         availability: availability(windows),
         windows: Enum.sort_by(windows, &(&1.duration_seconds || 9_999_999_999)),
         plan: plan
       }}
    else
      true -> {:error, :unsupported}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_paths([path | rest], credential, source) do
    result =
      with {:ok, body} <- HTTP.get(source, path, headers(credential, source.auth_scheme)) do
        parse(body)
      end

    case result do
      {:error, reason} when reason in [:authentication_failed, :not_found] and rest != [] ->
        fetch_paths(rest, credential, source)

      other ->
        other
    end
  end

  defp fetch_paths([], _credential, _source), do: {:error, :unsupported}

  defp validate_credential(%Credential{token: token}) do
    if Adapter.valid_header_value?(token), do: :ok, else: {:error, :authentication_failed}
  end

  defp headers(credential, auth_scheme) do
    authorization =
      case auth_scheme do
        :bearer -> "Bearer #{credential.token}"
        :raw -> credential.token
      end

    [
      {"authorization", authorization},
      {"accept", "application/json"},
      {"accept-language", "en-US,en"},
      {"content-type", "application/json"}
    ]
  end

  defp parse_window(%Limit{type: type} = raw) when type in @supported_limit_types do
    with {:ok, used_percent} <- Adapter.percent(raw.percentage, :invalid_response),
         {:ok, resets_at} <- reset_time(raw.next_reset_time),
         {:ok, duration_seconds} <- duration_seconds(raw.unit, raw.number) do
      {:ok,
       %Window{
         label: window_label(type, duration_seconds),
         used_percent: used_percent,
         remaining_percent: Adapter.remaining_percent(used_percent),
         resets_at: resets_at,
         duration_seconds: duration_seconds
       }}
    end
  end

  defp parse_window(%Limit{}), do: {:error, :unknown_limit_type}

  defp duration_seconds(nil, nil), do: {:ok, nil}

  defp duration_seconds(3, number) when is_number(number) and number > 0,
    do: {:ok, trunc(number * 3_600)}

  defp duration_seconds(6, number) when is_number(number) and number > 0,
    do: {:ok, trunc(number * 604_800)}

  defp duration_seconds(_unit, _number), do: {:error, :invalid_duration}

  defp window_label(_type, 18_000), do: "5 hour"
  defp window_label(_type, 604_800), do: "Weekly"
  defp window_label("TIME_LIMIT", _duration), do: "Monthly tools"
  defp window_label("CREDIT_LIMIT", _duration), do: "Credit limit"
  defp window_label("TOKENS_LIMIT", _duration), do: "Token limit"

  defp reset_time(nil), do: {:ok, nil}

  defp reset_time(value) when is_integer(value) and value >= 0 do
    unit = if value >= 100_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp reset_time(_value), do: {:error, :invalid_response}

  defp availability(windows) do
    cond do
      Enum.any?(windows, &(&1.used_percent >= 100)) -> :unavailable
      Enum.any?(windows, &(&1.used_percent >= 90)) -> :limited
      true -> :available
    end
  end
end
