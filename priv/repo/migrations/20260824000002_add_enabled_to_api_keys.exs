defmodule LLMProxy.Storage.Repo.Migrations.AddEnabledToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add(:enabled, :boolean, null: false, default: true)
    end
  end
end
