defmodule LLMProxy.Repo.Migrations.AddEnabledToApiKeys do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    drop(index(:api_keys, [:hash]))

    alter table(:api_keys) do
      add(:enabled, :boolean, null: false, default: true)
    end

    create(unique_index(:api_keys, [:hash]))
  end

  def down do
    drop(index(:api_keys, [:hash]))

    alter table(:api_keys) do
      remove(:enabled)
    end

    create(unique_index(:api_keys, [:hash]))
  end
end
