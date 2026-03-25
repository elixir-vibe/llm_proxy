defmodule LLMProxy.Repo.Migrations.AddCostTracking do
  use Ecto.Migration

  def change do
    alter table(:usage_log) do
      add :cost_usd, :float
    end

    alter table(:api_keys) do
      add :total_spend_usd, :float, default: 0.0
      add :max_budget_usd, :float
      add :budget_period, :string
    end
  end
end
