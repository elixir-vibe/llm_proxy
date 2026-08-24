defmodule LLMProxy.Repo.Migrations.AddContentCaptureToApiKeys do
  use Ecto.Migration

  import Ecto.Query

  defmodule ApiKey do
    use Ecto.Schema

    @primary_key false
    schema "api_keys" do
      field :trace_requests, :boolean
      field :capture_content, :boolean
    end
  end

  def up do
    # QuackDB cannot add a constrained column to an existing table. The API-key
    # schema supplies the false default for new rows; this migration backfills
    # every existing row before preserving the prior full-trace behavior.
    alter table(:api_keys) do
      add :capture_content, :boolean
    end

    flush()

    repo().update_all(ApiKey, set: [capture_content: false])

    from(key in ApiKey, where: key.trace_requests == true)
    |> repo().update_all(set: [capture_content: true])
  end

  def down do
    alter table(:api_keys) do
      remove :capture_content
    end
  end
end
