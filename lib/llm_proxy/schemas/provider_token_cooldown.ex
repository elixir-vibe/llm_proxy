defmodule LLMProxy.Schemas.ProviderTokenCooldown do
  @moduledoc "Persistent provider-token cooldown for one model or the complete account."

  use Ecto.Schema
  import Ecto.Changeset

  @fields [:token_id, :scope, :model_key, :available_at, :reason]
  @scope_values ["account", "model"]
  @reason_values ["rate_limited"]

  schema "provider_token_cooldowns" do
    field(:token_id, :integer)
    field(:scope, :string)
    field(:model_key, :string)
    field(:available_at, :utc_datetime_usec)
    field(:reason, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(cooldown, attrs) when is_map(attrs) do
    cooldown
    |> cast(attrs, @fields)
    |> reject_unknown_fields(attrs)
    |> validate_required(@fields)
    |> validate_number(:token_id, greater_than: 0)
    |> validate_inclusion(:scope, @scope_values)
    |> validate_format(:model_key, ~r/\A(?:account|[0-9a-f]{64})\z/)
    |> validate_inclusion(:reason, @reason_values)
    |> validate_scope_key()
    |> unique_constraint([:token_id, :scope, :model_key])
  end

  def changeset(cooldown, _attrs) do
    cooldown
    |> change()
    |> add_error(:base, "cooldown attributes must be a map")
  end

  defp reject_unknown_fields(changeset, attrs) do
    allowed = @fields ++ Enum.map(@fields, &Atom.to_string/1)

    case Map.keys(attrs) -- allowed do
      [] -> changeset
      _unknown -> add_error(changeset, :base, "contains unknown cooldown fields")
    end
  end

  defp validate_scope_key(changeset) do
    case {get_field(changeset, :scope), get_field(changeset, :model_key)} do
      {"account", "account"} ->
        changeset

      {"model", model_key} when is_binary(model_key) and byte_size(model_key) == 64 ->
        changeset

      {"account", _model_key} ->
        add_error(changeset, :model_key, "must use the account key for account scope")

      {"model", _model_key} ->
        add_error(changeset, :model_key, "must identify a model")

      _other ->
        changeset
    end
  end
end
