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
    migrator(opts).up()
  end

  def down(opts \\ []) do
    migrator(opts).down()
  end

  @doc false
  def migrator(opts \\ []) do
    repo = Keyword.get_lazy(opts, :repo, fn -> repo() end)
    ensure_supported_adapter!(repo.__adapter__())
    LLMProxy.Storage.Migrations.Schema
  end

  defp ensure_supported_adapter!(adapter)
       when adapter in [Ecto.Adapters.Postgres, Ecto.Adapters.SQLite3, Ecto.Adapters.MyXQL] do
    :ok
  end

  defp ensure_supported_adapter!(Ecto.Adapters.QuackDB) do
    if Code.ensure_loaded?(Ecto.Adapters.QuackDB) do
      :ok
    else
      raise "Ecto adapter #{inspect(Ecto.Adapters.QuackDB)} is not supported by LLMProxy migrations"
    end
  end

  defp ensure_supported_adapter!(other) do
    raise "Ecto adapter #{inspect(other)} is not supported by LLMProxy migrations"
  end
end
