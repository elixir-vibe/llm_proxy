defmodule LLMProxy.Storage.MigrationsTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Storage.Migrations

  defmodule PostgresRepo do
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  defmodule SQLiteRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3
  end

  defmodule MyXQLRepo do
    def __adapter__, do: Ecto.Adapters.MyXQL
  end

  defmodule QuackDBRepo do
    def __adapter__, do: Ecto.Adapters.QuackDB
  end

  test "dispatches migration modules by repo adapter" do
    assert Migrations.migrator(repo: PostgresRepo) == LLMProxy.Storage.Migrations.Postgres
    assert Migrations.migrator(repo: SQLiteRepo) == LLMProxy.Storage.Migrations.SQLite
    assert Migrations.migrator(repo: MyXQLRepo) == LLMProxy.Storage.Migrations.MyXQL
    assert Migrations.migrator(repo: QuackDBRepo) == LLMProxy.Storage.Migrations.QuackDB
  end
end
