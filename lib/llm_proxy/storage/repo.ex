defmodule LLMProxy.Storage.Repo do
  @moduledoc false

  def configured do
    repo = LLMProxy.Config.repo()

    if repo == LLMProxy.Repo and not Code.ensure_loaded?(LLMProxy.Repo) do
      raise """
      LLMProxy is configured to use the bundled SQLite repo, but ecto_sqlite3 is not available.

      Either add {:ecto_sqlite3, \"~> 0.17\"} to your dependencies for standalone SQLite storage,
      or configure LLMProxy to use your host repo:

          config :llm_proxy, repo: MyApp.Repo
      """
    end

    repo
  end

  def bundled?, do: configured() in [LLMProxy.Repo, LLMProxy.QuackRepo]

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
