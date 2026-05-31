defmodule LLMProxy.Repo.Migrations.CreateTraceFeedback do
  use Ecto.Migration

  def change do
    create table(:trace_feedback) do
      add :trace_id, references(:traces, on_delete: :nilify_all)
      add :request_id, :string, null: false
      add :key_id, :string, null: false
      add :rating, :string, null: false
      add :comment, :text
      add :metadata, :string
      add :timestamp, :utc_datetime, null: false
    end

    create index(:trace_feedback, [:trace_id])
    create index(:trace_feedback, [:request_id])
    create index(:trace_feedback, [:key_id])
    create index(:trace_feedback, [:timestamp])
  end
end
