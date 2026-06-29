defmodule LLMProxy.Schemas.ProviderToken do
  @moduledoc """
  Ecto schema for upstream provider API keys, OAuth tokens, labels, proxies, and enabled state.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          provider: String.t() | nil,
          kind: String.t() | nil,
          token: String.t() | nil,
          label: String.t() | nil,
          proxy: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          account_id: String.t() | nil,
          enabled: boolean(),
          added_at: DateTime.t() | nil
        }

  schema "provider_tokens" do
    field(:provider, :string)
    field(:kind, :string)
    field(:token, :string)
    field(:label, :string)
    field(:proxy, :string)
    field(:refresh_token, :string)
    field(:expires_at, :utc_datetime)
    field(:account_id, :string)
    field(:enabled, :boolean, default: true)
    field(:added_at, :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :provider,
      :kind,
      :token,
      :label,
      :proxy,
      :refresh_token,
      :expires_at,
      :account_id,
      :enabled,
      :added_at
    ])
    |> validate_required([:provider, :kind, :token, :added_at])
    |> validate_inclusion(:kind, ["api-key", "oauth"])
    |> validate_change(:proxy, &validate_proxy/2)
  end

  defp validate_proxy(:proxy, nil), do: []
  defp validate_proxy(:proxy, ""), do: []

  defp validate_proxy(:proxy, proxy) do
    case URI.parse(proxy) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> []
      _ -> [proxy: "must be an absolute http(s) URL"]
    end
  end
end
