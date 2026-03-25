defmodule LLMProxy.Repo.Migrations.CreateTraces do
  use Ecto.Migration

  def change do
    create table(:traces) do
      add :key_id, :string, null: false
      add :model, :string, null: false
      add :provider, :string
      add :request_body, :text
      add :response_body, :text
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :cost_usd, :float
      add :duration_ms, :integer
      add :ttft_ms, :integer
      add :tags, :string
      add :metadata, :string
      add :session_id, :string
      add :timestamp, :utc_datetime, null: false
    end

    create index(:traces, [:key_id])
    create index(:traces, [:session_id])
    create index(:traces, [:timestamp])
    create index(:traces, [:model])

    alter table(:api_keys) do
      add :trace_requests, :boolean, default: false
    end
  end
end
