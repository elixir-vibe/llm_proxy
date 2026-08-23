defmodule LLMProxy.Repo.Migrations.AddContentCaptureToApiKeys do
  use Ecto.Migration

  def up do
    alter table(:api_keys) do
      add :capture_content, :boolean, default: false, null: false
    end

    execute("UPDATE api_keys SET capture_content = TRUE WHERE trace_requests = TRUE")
  end

  def down do
    alter table(:api_keys) do
      remove :capture_content
    end
  end
end
