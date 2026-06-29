defmodule LLMProxy.Repo.Migrations.AddOauthRefreshFieldsToProviderTokens do
  use Ecto.Migration

  def change do
    alter table(:provider_tokens) do
      add(:refresh_token, :string)
      add(:expires_at, :utc_datetime)
      add(:account_id, :string)
    end
  end
end
