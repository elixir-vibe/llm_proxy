defmodule LLMProxy.Storage.Migrations do
  @moduledoc """
  Ecto migrations for host applications embedding LLMProxy storage.

  Call from a host migration:

      defmodule MyApp.Repo.Migrations.AddLLMProxy do
        use Ecto.Migration

        def up, do: LLMProxy.Storage.Migrations.up()
        def down, do: LLMProxy.Storage.Migrations.down()
      end
  """

  use Ecto.Migration

  def up(opts \\ []) do
    migrator(opts).up(opts)
  end

  def down(opts \\ []) do
    migrator(opts).down(opts)
  end

  defp migrator(opts) do
    repo = Keyword.get_lazy(opts, :repo, fn -> repo() end)

    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> LLMProxy.Storage.Migrations.Postgres
      Ecto.Adapters.SQLite3 -> LLMProxy.Storage.Migrations.SQLite
      Ecto.Adapters.MyXQL -> LLMProxy.Storage.Migrations.MyXQL
      other -> raise "Ecto adapter #{inspect(other)} is not supported by LLMProxy migrations"
    end
  end
end
