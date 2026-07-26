defmodule LLMProxy.Repo.Migrations.WidenTokenCounters do
  use Ecto.Migration

  def up do
    case repo().__adapter__() do
      Ecto.Adapters.QuackDB -> widen_quackdb_columns()
      Ecto.Adapters.SQLite3 -> :ok
    end
  end

  defp widen_quackdb_columns do
    drop(index(:api_keys, [:hash]))
    drop(index(:usage_log, [:key_id]))
    drop(index(:usage_log, [:timestamp]))
    drop(index(:traces, [:key_id]))
    drop(index(:traces, [:model]))
    drop(index(:traces, [:session_id]))
    drop(index(:traces, [:timestamp]))
    drop(index(:message_log, [:key_id]))
    drop(index(:message_log, [:timestamp]))

    alter table(:api_keys) do
      modify(:quota_4h_input, :bigint)
    end

    alter table(:api_keys) do
      modify(:quota_4h_output, :bigint)
    end

    alter table(:api_keys) do
      modify(:quota_week_input, :bigint)
    end

    alter table(:api_keys) do
      modify(:quota_week_output, :bigint)
    end

    alter table(:api_keys) do
      modify(:input_tokens, :bigint)
    end

    alter table(:api_keys) do
      modify(:output_tokens, :bigint)
    end

    alter table(:api_keys) do
      modify(:cache_read_tokens, :bigint)
    end

    alter table(:api_keys) do
      modify(:cache_write_tokens, :bigint)
    end

    alter table(:usage_log) do
      modify(:input_tokens, :bigint)
    end

    alter table(:usage_log) do
      modify(:output_tokens, :bigint)
    end

    alter table(:usage_log) do
      modify(:cache_read_tokens, :bigint)
    end

    alter table(:usage_log) do
      modify(:cache_write_tokens, :bigint)
    end

    alter table(:traces) do
      modify(:input_tokens, :bigint)
    end

    alter table(:traces) do
      modify(:output_tokens, :bigint)
    end

    alter table(:message_log) do
      modify(:input_tokens, :bigint)
    end

    alter table(:message_log) do
      modify(:output_tokens, :bigint)
    end

    create(unique_index(:api_keys, [:hash]))
    create(index(:usage_log, [:key_id]))
    create(index(:usage_log, [:timestamp]))
    create(index(:traces, [:key_id]))
    create(index(:traces, [:model]))
    create(index(:traces, [:session_id]))
    create(index(:traces, [:timestamp]))
    create(index(:message_log, [:key_id]))
    create(index(:message_log, [:timestamp]))
  end
end
