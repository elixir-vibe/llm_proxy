defmodule LLMProxy.Repo.Migrations.AddLatencyTracking do
  use Ecto.Migration

  def change do
    alter table(:usage_log) do
      add :duration_ms, :integer
      add :ttft_ms, :integer
      add :provider, :string
    end
  end
end
