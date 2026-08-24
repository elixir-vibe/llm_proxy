defmodule LLMProxy.Schemas.ProviderTokenCooldown do
  @moduledoc "Persistent provider-token cooldown for one model or the complete account."

  use Ecto.Schema
  import Ecto.Changeset

  schema "provider_token_cooldowns" do
    field(:token_id, :integer)
    field(:model, :string)
    field(:available_at, :utc_datetime_usec)
    field(:reason, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(cooldown, attrs) do
    cooldown
    |> cast(attrs, [:token_id, :model, :available_at, :reason])
    |> validate_required([:token_id, :model, :available_at, :reason])
    |> unique_constraint([:token_id, :model])
  end
end
