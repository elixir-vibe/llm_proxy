defmodule LLMProxy.Storage.Repo do
  @moduledoc false

  def configured, do: LLMProxy.Config.repo()

  def bundled?, do: configured() == LLMProxy.Repo

  def adapter, do: configured().__adapter__()
  def config, do: configured().config()

  def all(queryable, opts \\ []), do: configured().all(queryable, opts)
  def delete(struct, opts \\ []), do: configured().delete(struct, opts)
  def delete_all(queryable, opts \\ []), do: configured().delete_all(queryable, opts)
  def get(queryable, id, opts \\ []), do: configured().get(queryable, id, opts)
  def get_by(queryable, clauses, opts \\ []), do: configured().get_by(queryable, clauses, opts)
  def insert(changeset, opts \\ []), do: configured().insert(changeset, opts)
  def one(queryable, opts \\ []), do: configured().one(queryable, opts)
  def query(sql, params \\ [], opts \\ []), do: configured().query(sql, params, opts)
  def update(changeset, opts \\ []), do: configured().update(changeset, opts)

  def update_all(queryable, updates, opts \\ []),
    do: configured().update_all(queryable, updates, opts)
end
