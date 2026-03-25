defmodule LLMProxy.Repo.Migrations.AddMetadataTags do
  use Ecto.Migration

  def change do
    alter table(:usage_log) do
      add :tags, :string
      add :metadata, :string
    end
  end
end
