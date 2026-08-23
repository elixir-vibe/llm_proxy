defmodule LLMProxy.ProviderUsage.Adapters.GLM do
  @moduledoc "Live Z.AI GLM Coding Plan usage adapter."

  @behaviour LLMProxy.ProviderUsage.Adapter

  alias LLMProxy.Provider.Credential
  alias LLMProxy.ProviderUsage.{Adapter, HTTP, Result, Source, Window}

  @supported_limit_types ~w(TOKENS_LIMIT CREDIT_LIMIT TIME_LIMIT)

  @impl true
  def fetch(%Credential{} = credential, %Source{} = source) do
    with :ok <- validate_credential(credential) do
      fetch_paths(source.usage_paths, credential, source)
    end
  end

  @doc false
  @spec parse(map()) :: {:ok, Result.t()} | {:error, atom()}
  def parse(%{"code" => code}) when code in [401, 403], do: {:error, :authentication_failed}

  def parse(%{"success" => false}), do: {:error, :unsupported}

  def parse(body) when is_map(body) do
    data = if is_map(body["data"]), do: body["data"], else: body

    with limits when is_list(limits) <- data["limits"],
         {:ok, windows} <- parse_windows(limits),
         false <- windows == [] do
      {:ok,
       %Result{
         availability: availability(windows),
         windows: Enum.sort_by(windows, &(&1.duration_seconds || 9_999_999_999)),
         plan: Adapter.safe_plan(data["level"])
       }}
    else
      nil -> {:error, :unsupported}
      true -> {:error, :unsupported}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_response}
    end
  end

  def parse(_body), do: {:error, :invalid_response}

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

  defp parse_windows(limits) do
    limits
    |> Enum.filter(&(is_map(&1) and &1["type"] in @supported_limit_types))
    |> Adapter.collect(&parse_window/1)
  end

  defp parse_window(raw) do
    with {:ok, used_percent} <- Adapter.percent(raw["percentage"], :invalid_response),
         {:ok, resets_at} <- reset_time(raw["nextResetTime"]) do
      duration_seconds = duration_seconds(raw["unit"], raw["number"])

      {:ok,
       %Window{
         label: window_label(raw["type"], duration_seconds),
         used_percent: used_percent,
         remaining_percent: Adapter.remaining_percent(used_percent),
         resets_at: resets_at,
         duration_seconds: duration_seconds
       }}
    end
  end

  defp duration_seconds(3, number) when is_number(number) and number > 0,
    do: trunc(number * 3_600)

  defp duration_seconds(6, number) when is_number(number) and number > 0,
    do: trunc(number * 604_800)

  defp duration_seconds(_unit, _number), do: nil

  defp window_label(_type, 18_000), do: "5 hour"
  defp window_label(_type, 604_800), do: "Weekly"
  defp window_label("TIME_LIMIT", _duration), do: "Monthly tools"
  defp window_label("CREDIT_LIMIT", _duration), do: "Credit limit"
  defp window_label(_type, _duration), do: "Token limit"

  defp reset_time(nil), do: {:ok, nil}

  defp reset_time(value) when is_integer(value) do
    unit = if value >= 100_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp reset_time(value) when is_float(value), do: reset_time(trunc(value))

  defp reset_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> reset_time(integer)
      _other -> {:error, :invalid_response}
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
