defmodule LLMProxy.Repo.Migrations.AddPriorityToProviderTokens do
  use Ecto.Migration

  def change do
    alter table(:provider_tokens) do
      add(:priority, :integer, default: 0, null: false)
    end
  end
end
