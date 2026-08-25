defmodule LLMProxy.Repo.Migrations.AddPriorityToProviderTokens do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    drop(index(:provider_tokens, [:provider, :kind]))

    alter table(:provider_tokens) do
      add(:priority, :integer, default: 0, null: false)
    end

    create(index(:provider_tokens, [:provider, :kind]))
  end

  def down do
    drop(index(:provider_tokens, [:provider, :kind]))

    alter table(:provider_tokens) do
      remove(:priority)
    end

    create(index(:provider_tokens, [:provider, :kind]))
  end
end
