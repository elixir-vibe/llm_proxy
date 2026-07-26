defmodule LLMProxy.Repo.Migrations.WidenTokenCounters do
  use Ecto.Migration

  def up do
    case repo().__adapter__() do
      Ecto.Adapters.QuackDB -> widen_quackdb_columns()
      Ecto.Adapters.SQLite3 -> :ok
    end
  end

  defp widen_quackdb_columns do
    execute("ALTER TABLE api_keys ALTER COLUMN quota_4h_input TYPE BIGINT")
    execute("ALTER TABLE api_keys ALTER COLUMN quota_4h_output TYPE BIGINT")
    execute("ALTER TABLE api_keys ALTER COLUMN quota_week_input TYPE BIGINT")
    execute("ALTER TABLE api_keys ALTER COLUMN quota_week_output TYPE BIGINT")
    execute("ALTER TABLE api_keys ALTER COLUMN input_tokens TYPE BIGINT")
    execute("ALTER TABLE api_keys ALTER COLUMN output_tokens TYPE BIGINT")
    execute("ALTER TABLE api_keys ALTER COLUMN cache_read_tokens TYPE BIGINT")
    execute("ALTER TABLE api_keys ALTER COLUMN cache_write_tokens TYPE BIGINT")

    execute("ALTER TABLE usage_log ALTER COLUMN input_tokens TYPE BIGINT")
    execute("ALTER TABLE usage_log ALTER COLUMN output_tokens TYPE BIGINT")
    execute("ALTER TABLE usage_log ALTER COLUMN cache_read_tokens TYPE BIGINT")
    execute("ALTER TABLE usage_log ALTER COLUMN cache_write_tokens TYPE BIGINT")

    execute("ALTER TABLE traces ALTER COLUMN input_tokens TYPE BIGINT")
    execute("ALTER TABLE traces ALTER COLUMN output_tokens TYPE BIGINT")

    execute("ALTER TABLE message_log ALTER COLUMN input_tokens TYPE BIGINT")
    execute("ALTER TABLE message_log ALTER COLUMN output_tokens TYPE BIGINT")
  end
end
