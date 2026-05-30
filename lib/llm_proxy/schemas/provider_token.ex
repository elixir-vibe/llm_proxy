defmodule LLMProxy.Schemas.ProviderToken do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "provider_tokens" do
    field(:provider, :string)
    field(:kind, :string)
    field(:token, :string)
    field(:label, :string)
    field(:proxy, :string)
    field(:enabled, :boolean, default: true)
    field(:added_at, :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:provider, :kind, :token, :label, :proxy, :enabled, :added_at])
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
