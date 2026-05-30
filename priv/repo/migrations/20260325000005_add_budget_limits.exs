defmodule LLMProxy.Repo.Migrations.AddBudgetLimits do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :budget_limits, :string
    end
  end
end
