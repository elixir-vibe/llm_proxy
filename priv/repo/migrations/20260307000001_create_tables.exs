defmodule LLMProxy.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :string, primary_key: true
      add :hash, :string, null: false
      add :name, :string, null: false
      add :quota_4h_input, :integer
      add :quota_4h_output, :integer
      add :quota_week_input, :integer
      add :quota_week_output, :integer
      add :quota_4h_messages, :integer
      add :quota_week_messages, :integer
      add :min_cache_ratio, :float
      add :allowed_models, :string
      add :service_quotas, :string
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :cache_read_tokens, :integer, default: 0
      add :cache_write_tokens, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:hash])

    create table(:usage_log) do
      add :key_id, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, null: false
      add :output_tokens, :integer, null: false
      add :cache_read_tokens, :integer, default: 0
      add :cache_write_tokens, :integer, default: 0
      add :timestamp, :utc_datetime, null: false
    end

    create index(:usage_log, [:key_id])
    create index(:usage_log, [:timestamp])

    create table(:service_usage_log) do
      add :key_id, :string, null: false
      add :service, :string, null: false
      add :endpoint, :string, null: false
      add :timestamp, :utc_datetime, null: false
    end

    create index(:service_usage_log, [:key_id])
    create index(:service_usage_log, [:service])
    create index(:service_usage_log, [:timestamp])

    create table(:provider_tokens) do
      add :provider, :string, null: false
      add :kind, :string, null: false
      add :token, :string, null: false
      add :label, :string
      add :proxy, :string
      add :enabled, :boolean, default: true, null: false
      add :added_at, :utc_datetime, null: false
    end

    create index(:provider_tokens, [:provider, :kind])

    create table(:message_log) do
      add :key_id, :string, null: false
      add :model, :string, null: false
      add :route, :string, null: false
      add :user_message, :string, null: false
      add :timestamp, :utc_datetime, null: false
    end

    create index(:message_log, [:key_id])
    create index(:message_log, [:timestamp])
  end
end
