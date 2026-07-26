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

    create_if_not_exists(unique_index(:api_keys, [:hash]))
  end
end
