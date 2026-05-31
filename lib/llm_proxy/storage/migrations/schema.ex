defmodule LLMProxy.Storage.Migrations.Schema do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:api_keys, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:hash, :string, null: false)
      add(:name, :string, null: false)
      add(:quota_4h_input, :integer)
      add(:quota_4h_output, :integer)
      add(:quota_week_input, :integer)
      add(:quota_week_output, :integer)
      add(:quota_4h_messages, :integer)
      add(:quota_week_messages, :integer)
      add(:min_cache_ratio, :float)
      add(:allowed_models, :string)
      add(:service_quotas, :string)
      add(:input_tokens, :integer, default: 0)
      add(:output_tokens, :integer, default: 0)
      add(:cache_read_tokens, :integer, default: 0)
      add(:cache_write_tokens, :integer, default: 0)
      add(:total_spend_usd, :float, default: 0.0)
      add(:max_budget_usd, :float)
      add(:budget_period, :string)
      add(:budget_limits, :string)
      add(:trace_requests, :boolean, default: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:api_keys, [:hash]))

    create table(:usage_log) do
      add(:key_id, :string, null: false)
      add(:model, :string, null: false)
      add(:input_tokens, :integer, null: false)
      add(:output_tokens, :integer, null: false)
      add(:cache_read_tokens, :integer, default: 0)
      add(:cache_write_tokens, :integer, default: 0)
      add(:cost_usd, :float)
      add(:duration_ms, :integer)
      add(:ttft_ms, :integer)
      add(:provider, :string)
      add(:tags, :string)
      add(:metadata, :string)
      add(:timestamp, :utc_datetime, null: false)
    end

    create(index(:usage_log, [:key_id]))
    create(index(:usage_log, [:timestamp]))

    create table(:service_usage_log) do
      add(:key_id, :string, null: false)
      add(:service, :string, null: false)
      add(:endpoint, :string, null: false)
      add(:timestamp, :utc_datetime, null: false)
    end

    create(index(:service_usage_log, [:key_id]))
    create(index(:service_usage_log, [:service]))
    create(index(:service_usage_log, [:timestamp]))

    create table(:provider_tokens) do
      add(:provider, :string, null: false)
      add(:kind, :string, null: false)
      add(:token, :string, null: false)
      add(:label, :string)
      add(:proxy, :string)
      add(:enabled, :boolean, default: true, null: false)
      add(:added_at, :utc_datetime, null: false)
    end

    create(index(:provider_tokens, [:provider, :kind]))

    create table(:message_log) do
      add(:key_id, :string, null: false)
      add(:model, :string, null: false)
      add(:route, :string, null: false)
      add(:user_message, :text, null: false)
      add(:timestamp, :utc_datetime, null: false)
    end

    create(index(:message_log, [:key_id]))
    create(index(:message_log, [:timestamp]))

    create table(:traces) do
      add(:key_id, :string, null: false)
      add(:model, :string, null: false)
      add(:provider, :string)
      add(:request_body, :text)
      add(:response_body, :text)
      add(:input_tokens, :integer, default: 0)
      add(:output_tokens, :integer, default: 0)
      add(:cost_usd, :float)
      add(:duration_ms, :integer)
      add(:ttft_ms, :integer)
      add(:tags, :string)
      add(:metadata, :string)
      add(:session_id, :string)
      add(:timestamp, :utc_datetime, null: false)
    end

    create(index(:traces, [:key_id]))
    create(index(:traces, [:session_id]))
    create(index(:traces, [:timestamp]))
    create(index(:traces, [:model]))

    create table(:trace_feedback) do
      add(:trace_id, references(:traces, on_delete: :nilify_all))
      add(:request_id, :string, null: false)
      add(:key_id, :string, null: false)
      add(:rating, :string, null: false)
      add(:comment, :text)
      add(:metadata, :string)
      add(:timestamp, :utc_datetime, null: false)
    end

    create(index(:trace_feedback, [:trace_id]))
    create(index(:trace_feedback, [:request_id]))
    create(index(:trace_feedback, [:key_id]))
    create(index(:trace_feedback, [:timestamp]))
  end

  def down do
    drop(table(:trace_feedback))
    drop(table(:traces))
    drop(table(:message_log))
    drop(table(:provider_tokens))
    drop(table(:service_usage_log))
    drop(table(:usage_log))
    drop(table(:api_keys))
  end
end
