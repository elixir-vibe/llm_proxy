defmodule LLMProxy.Repo.Migrations.WidenProviderTokenFields do
  use Ecto.Migration

  def up do
    case repo().__adapter__() do
      Ecto.Adapters.SQLite3 -> :ok
      Ecto.Adapters.QuackDB -> :ok
      _adapter -> widen_fields()
    end
  end

  defp widen_fields do
    alter table(:provider_tokens) do
      modify(:token, :text, null: false)
    end

    alter table(:provider_tokens) do
      modify(:refresh_token, :text)
    end
  end
end
