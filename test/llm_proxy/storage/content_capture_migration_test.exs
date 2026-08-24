defmodule LLMProxy.Storage.ContentCaptureMigrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260823000001_add_content_capture_to_api_keys.exs",
                    __DIR__
                  )

  unless Code.ensure_loaded?(LLMProxy.Repo.Migrations.AddContentCaptureToApiKeys) do
    Code.require_file(@migration_path)
  end

  defmodule LegacyApiKeysMigration do
    use Ecto.Migration

    def change do
      create table(:api_keys, primary_key: false) do
        add(:id, :string, primary_key: true)
        add(:trace_requests, :boolean, default: false, null: false)
      end
    end
  end

  defmodule LegacyApiKey do
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "api_keys" do
      field(:trace_requests, :boolean)
    end
  end

  defmodule MigratedApiKey do
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "api_keys" do
      field(:trace_requests, :boolean)
      field(:capture_content, :boolean)
    end
  end

  defmodule SQLiteRepo do
    use Ecto.Repo,
      otp_app: :llm_proxy,
      adapter: Ecto.Adapters.SQLite3
  end

  defmodule QuackDBRepo do
    use Ecto.Repo,
      otp_app: :llm_proxy,
      adapter: Ecto.Adapters.QuackDB
  end

  test "preserves traced-key capture and disables other keys on SQLite" do
    database = tmp_path("sqlite", ".db")

    Application.put_env(:llm_proxy, SQLiteRepo,
      database: database,
      pool_size: 1
    )

    on_exit(fn ->
      Application.delete_env(:llm_proxy, SQLiteRepo)
      File.rm(database)
    end)

    start_supervised!(SQLiteRepo)
    assert_migration_policy(SQLiteRepo)
  end

  @tag :integration
  test "preserves traced-key capture and disables other keys on QuackDB" do
    port = available_port()
    endpoint = "quack:localhost:#{port}"

    server =
      start_supervised!(
        {QuackDB.Server,
         duckdb: :managed, endpoint: endpoint, token: "migration-test-token", wait_timeout: 30_000}
      )

    Application.put_env(:llm_proxy, QuackDBRepo,
      uri: QuackDB.Server.uri(server),
      token: QuackDB.Server.token(server),
      pool_size: 1
    )

    on_exit(fn -> Application.delete_env(:llm_proxy, QuackDBRepo) end)

    start_supervised!(QuackDBRepo)
    assert_migration_policy(QuackDBRepo)
  end

  defp assert_migration_policy(repo) do
    assert :ok = Ecto.Migrator.up(repo, 1, LegacyApiKeysMigration, log: false)

    assert %LegacyApiKey{} =
             repo.insert!(%LegacyApiKey{id: "capture", trace_requests: true})

    assert %LegacyApiKey{} =
             repo.insert!(%LegacyApiKey{id: "private", trace_requests: false})

    assert repo.all(
             from(key in LegacyApiKey,
               order_by: key.id,
               select: {key.id, key.trace_requests}
             )
           ) == [{"capture", true}, {"private", false}]

    assert :ok =
             Ecto.Migrator.up(
               repo,
               20_260_823_000_001,
               LLMProxy.Repo.Migrations.AddContentCaptureToApiKeys,
               log: false
             )

    assert repo.all(
             from(key in MigratedApiKey,
               order_by: key.id,
               select: {key.id, key.capture_content}
             )
           ) == [{"capture", true}, {"private", false}]
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp tmp_path(name, extension) do
    Path.join(
      System.tmp_dir!(),
      "llm-proxy-#{name}-#{System.unique_integer([:positive])}#{extension}"
    )
  end
end
