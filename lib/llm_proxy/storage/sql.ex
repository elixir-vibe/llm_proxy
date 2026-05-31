defmodule LLMProxy.Storage.SQL do
  @moduledoc false

  alias LLMProxy.Storage.Repo

  def adapter do
    case Repo.adapter() do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.SQLite3 -> :sqlite
      Ecto.Adapters.MyXQL -> :mysql
      other -> {:unsupported, other}
    end
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
