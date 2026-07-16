defmodule LLMProxy.Repo.Migrations.AddTokensToMessageLog do
  use Ecto.Migration

  def change do
    alter table(:message_log) do
      add(:input_tokens, :integer)
      add(:output_tokens, :integer)
    end
  end
end
