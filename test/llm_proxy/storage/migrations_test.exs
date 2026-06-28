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

  test "accepts supported repo adapters" do
    assert Migrations.migrator(repo: PostgresRepo) == Migrations
    assert Migrations.migrator(repo: SQLiteRepo) == Migrations
    assert Migrations.migrator(repo: MyXQLRepo) == Migrations
    assert Migrations.migrator(repo: QuackDBRepo) == Migrations
  end
end
