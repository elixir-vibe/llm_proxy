defmodule LLMProxy.ReleaseTasks do
  @moduledoc """
  Release-safe operational tasks for standalone LLMProxy deployments.

  These functions are intended to be called through `bin/llm_proxy eval ...`
  by systemd jobs or operators. They avoid Mix so they work from an OTP release.
  """

  @doc "Runs all pending Ecto migrations for the configured LLMProxy repo."
  @spec migrate() :: :ok
  def migrate do
    repo = LLMProxy.Config.repo()
    migration_source = Ecto.Migrator.migrations_path(repo)

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, fn started_repo ->
        Ecto.Migrator.run(started_repo, migration_source, :up, all: true)
      end)

    :ok
  end
end
