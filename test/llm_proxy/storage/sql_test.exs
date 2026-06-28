defmodule LLMProxy.Storage.SQLTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Storage.SQL

  defmodule PostgresRepo do
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  defmodule MyXQLRepo do
    def __adapter__, do: Ecto.Adapters.MyXQL
  end

  defmodule QuackDBRepo do
    def __adapter__, do: Ecto.Adapters.QuackDB
  end

  setup do
    original = Application.get_env(:llm_proxy, :repo)

    on_exit(fn ->
      if original do
        Application.put_env(:llm_proxy, :repo, original)
      else
        Application.delete_env(:llm_proxy, :repo)
      end
    end)
  end

  test "detects configured repo adapters" do
    Application.put_env(:llm_proxy, :repo, PostgresRepo)
    assert SQL.adapter() == :postgres

    Application.put_env(:llm_proxy, :repo, MyXQLRepo)
    assert SQL.adapter() == :mysql

    Application.put_env(:llm_proxy, :repo, LLMProxy.Storage.Repo.SQLite)
    assert SQL.adapter() == :sqlite

    Application.put_env(:llm_proxy, :repo, QuackDBRepo)
    assert SQL.adapter() == :quackdb
  end
end
