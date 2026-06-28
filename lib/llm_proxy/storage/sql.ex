defmodule LLMProxy.Storage.SQL do
  @moduledoc """
  SQL adapter detection and support checks for storage queries and migrations.
  """

  alias LLMProxy.Storage.Repo

  def adapter do
    case Repo.adapter() do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.SQLite3 -> :sqlite
      Ecto.Adapters.MyXQL -> :mysql
      Ecto.Adapters.QuackDB -> quackdb_adapter()
      other -> {:unsupported, other}
    end
  end

  defp quackdb_adapter do
    if Code.ensure_loaded?(Ecto.Adapters.QuackDB),
      do: :quackdb,
      else: {:unsupported, Ecto.Adapters.QuackDB}
  end

  def supported_adapter! do
    case adapter() do
      {:unsupported, other} ->
        raise "Ecto adapter #{inspect(other)} is not supported by LLMProxy storage"

      adapter ->
        adapter
    end
  end
end
