defmodule LLMProxy.Providers.OpenAICodex.OAuth do
  @moduledoc """
  OAuth credential refresh boundary for the OpenAI Codex provider.

  ReqLLM returns refreshed OpenAI credentials as provider JSON with string keys.
  This module is the only place in LLMProxy that parses that external shape and
  converts it into typed data and atom-keyed storage updates.
  """

  alias LLMProxy.Provider.Credential
  alias LLMProxy.Provider.TokenCodec
  alias LLMProxy.Schemas.ProviderToken

  defmodule RefreshResponse do
    @moduledoc """
    ReqLLM OpenAI Codex OAuth refresh response.

    This struct is the JSON boundary for refresh credentials returned by ReqLLM.
    """

    use JSONCodec, case: :camel, strict: true, fast_path: :json

    defstruct [:access, :refresh, :expires_at, :account_id]

    @type t :: %__MODULE__{
            access: String.t(),
            refresh: String.t(),
            expires_at: DateTime.t(),
            account_id: String.t() | nil
          }

    codec(:expires_at, as: "expires", cast: :expires_datetime)

    def expires_datetime(expires) when is_integer(expires) do
      expires |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)
    end
  end

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

  @spec refresh_if_needed(Credential.t() | ProviderToken.t(), refresh_fun()) ::
          {:ok, Credential.t() | ProviderToken.t()} | {:error, term()}
  def refresh_if_needed(%Credential{} = token, refresh_fun)
      when is_function(refresh_fun, 2) do
    if refreshable_expired?(token) do
      refresh(token, refresh_fun)
    else
      {:ok, token}
    end
  end

  def refresh_if_needed(%ProviderToken{} = stored, refresh_fun)
      when is_function(refresh_fun, 2) do
    with {:ok, credential} <- TokenCodec.credential(stored),
         result <- refresh_if_needed(credential, refresh_fun) do
      case result do
        {:ok, ^credential} -> {:ok, stored}
        other -> other
      end
    end
  end

  defp refreshable_expired?(%Credential{
         refresh_token: refresh_token,
         expires_at: %DateTime{} = expires_at
       })
       when is_binary(refresh_token) and refresh_token != "" do
    DateTime.compare(expires_at, refresh_deadline()) != :gt
  end

  defp refreshable_expired?(_token), do: false

  defp refresh(%Credential{} = token, refresh_fun) do
    with {:ok, refreshed} <- refresh_fun.(refresh_request(token), []),
         {:ok, credentials} <- from_refresh_response(refreshed),
         {:ok, stored} <-
           LLMProxy.Storage.update_token_oauth(token.id, storage_attrs(credentials)) do
      TokenCodec.for_provider(stored)
    end
  end

  defp refresh_request(%Credential{} = token) do
    %{access: token.token, refresh: token.refresh_token, expires: expires_ms(token.expires_at)}
  end

  @spec new(String.t(), String.t(), DateTime.t(), String.t() | nil) ::
          {:ok, t()} | {:error, String.t()}
  def new(access, refresh, %DateTime{} = expires_at, account_id \\ nil) do
    with :ok <- require_non_empty_string(access, "access"),
         :ok <- require_non_empty_string(refresh, "refresh"),
         {:ok, account_id} <- optional_string(account_id, "accountId") do
      {:ok,
       %__MODULE__{
         access: access,
         refresh: refresh,
         expires_at: DateTime.truncate(expires_at, :second),
         account_id: account_id
       }}
    end
  end

  @spec from_refresh_response(map()) :: {:ok, t()} | {:error, term()}
  def from_refresh_response(refreshed) when is_map(refreshed) do
    case RefreshResponse.from_map(refreshed) do
      {:ok, response} ->
        new(response.access, response.refresh, response.expires_at, response.account_id)

      {:error, reason} ->
        {:error, {:invalid_refresh_response, reason}}
    end
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
