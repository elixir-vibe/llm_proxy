defmodule LLMProxy.Repo.Migrations.CreateProviderTokenCooldowns do
  use Ecto.Migration

  def change do
    create table(:provider_token_cooldowns) do
      add(:token_id, :integer, null: false)
      add(:scope, :string, null: false)
      add(:model_key, :string, null: false)
      add(:available_at, :utc_datetime_usec, null: false)
      add(:reason, :string, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:provider_token_cooldowns, [:token_id, :scope, :model_key])
    create index(:provider_token_cooldowns, [:available_at])
  end
end
