defmodule LlmProxy.Schemas.ProviderToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "provider_tokens" do
    field :provider, :string
    field :kind, :string
    field :token, :string
    field :label, :string
    field :proxy, :string
    field :enabled, :boolean, default: true
    field :added_at, :utc_datetime
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:provider, :kind, :token, :label, :proxy, :enabled, :added_at])
    |> validate_required([:provider, :kind, :token, :added_at])
  end
end
