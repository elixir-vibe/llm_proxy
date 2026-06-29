defmodule LLMProxy.Providers.OpenAICodex.OAuth do
  @moduledoc """
  OAuth credential refresh boundary for the OpenAI Codex provider.

  ReqLLM returns refreshed OpenAI credentials as provider JSON with string keys.
  This module is the only place in LLMProxy that parses that external shape and
  converts it into typed data and atom-keyed storage updates.
  """

  alias LLMProxy.Schemas.ProviderToken

  @refresh_skew_seconds 60

  @enforce_keys [:access, :refresh, :expires_at]
  defstruct [:access, :refresh, :expires_at, :account_id]

  @type t :: %__MODULE__{
          access: String.t(),
          refresh: String.t(),
          expires_at: DateTime.t(),
          account_id: String.t() | nil
        }

  @type refresh_fun :: (map(), keyword() -> {:ok, map()} | {:error, term()})

  @spec refresh_if_needed(ProviderToken.t(), refresh_fun()) ::
          {:ok, ProviderToken.t()} | {:error, term()}
  def refresh_if_needed(%ProviderToken{} = token, refresh_fun) when is_function(refresh_fun, 2) do
    if refreshable_expired?(token) do
      refresh(token, refresh_fun)
    else
      {:ok, token}
    end
  end

  defp refreshable_expired?(%ProviderToken{
         refresh_token: refresh_token,
         expires_at: %DateTime{} = expires_at
       })
       when is_binary(refresh_token) and refresh_token != "" do
    DateTime.compare(expires_at, refresh_deadline()) != :gt
  end

  defp refreshable_expired?(_token), do: false

  defp refresh(%ProviderToken{} = token, refresh_fun) do
    with {:ok, refreshed} <- refresh_fun.(refresh_request(token), []),
         {:ok, credentials} <- parse_refreshed(refreshed) do
      LLMProxy.Storage.update_token_oauth(token.id, storage_attrs(credentials))
    end
  end

  defp refresh_request(%ProviderToken{} = token) do
    %{access: token.token, refresh: token.refresh_token, expires: expires_ms(token.expires_at)}
  end

  @spec parse_refreshed(map()) :: {:ok, t()} | {:error, String.t()}
  def parse_refreshed(%{"access" => access, "refresh" => refresh, "expires" => expires} = payload) do
    with :ok <- require_non_empty_string(access, "access"),
         :ok <- require_non_empty_string(refresh, "refresh"),
         {:ok, expires_at} <- parse_expires(expires),
         {:ok, account_id} <- optional_string(Map.get(payload, "accountId"), "accountId") do
      {:ok,
       %__MODULE__{
         access: access,
         refresh: refresh,
         expires_at: expires_at,
         account_id: account_id
       }}
    end
  end

  def parse_refreshed(_payload) do
    {:error, "OpenAI OAuth refresh response must include access, refresh, and expires"}
  end

  @spec storage_attrs(t()) :: map()
  def storage_attrs(%__MODULE__{} = credentials) do
    %{
      token: credentials.access,
      refresh_token: credentials.refresh,
      expires_at: credentials.expires_at,
      account_id: credentials.account_id
    }
  end

  defp refresh_deadline do
    DateTime.utc_now()
    |> DateTime.add(@refresh_skew_seconds, :second)
    |> DateTime.truncate(:second)
  end

  defp expires_ms(nil), do: nil
  defp expires_ms(%DateTime{} = expires_at), do: DateTime.to_unix(expires_at, :millisecond)

  defp parse_expires(expires) when is_integer(expires) do
    {:ok, expires |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)}
  end

  defp parse_expires(expires) do
    {:error,
     "OpenAI OAuth refresh response expires must be a Unix millisecond integer, got: #{inspect(expires)}"}
  end

  defp require_non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp require_non_empty_string(value, field) do
    {:error,
     "OpenAI OAuth refresh response #{field} must be a non-empty string, got: #{inspect(value)}"}
  end

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}

  defp optional_string(value, field) do
    {:error,
     "OpenAI OAuth refresh response #{field} must be a non-empty string when present, got: #{inspect(value)}"}
  end
end
