defmodule LLMProxy.Repo.Migrations.AddContentCaptureToApiKeys do
  use Ecto.Migration

  import Ecto.Query

  @disable_ddl_transaction true

  def up do
    drop(index(:api_keys, [:hash]))

    alter table(:api_keys) do
      add(:capture_content, :boolean, default: false, null: false)
    end

    flush()

    from("api_keys",
      where: [trace_requests: true],
      update: [set: [capture_content: type(^true, :boolean)]]
    )
    |> repo().update_all([])

    create(unique_index(:api_keys, [:hash]))
  end

  def down do
    drop(index(:api_keys, [:hash]))

    alter table(:api_keys) do
      remove(:capture_content)
    end

    create(unique_index(:api_keys, [:hash]))
  end
end
