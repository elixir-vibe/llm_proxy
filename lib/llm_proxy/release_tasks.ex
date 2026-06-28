defmodule LLMProxy.ReleaseTasks do
  @moduledoc """
  Release-safe operational tasks for standalone LLMProxy deployments.

  These functions are intended to be called through `bin/llm_proxy eval ...`
  by systemd jobs or operators. They avoid Mix so they work from an OTP release.
  """

  alias LLMProxy.Storage.Repo

  @doc "Runs all pending Ecto migrations for the configured LLMProxy repo."
  @spec migrate() :: :ok
  def migrate do
    repo = LLMProxy.Config.repo()
    migration_source = Application.app_dir(:llm_proxy, "priv/repo/migrations")

    with_quackdb_server(fn ->
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, fn started_repo ->
          migrations = Ecto.Migrator.run(started_repo, migration_source, :up, all: true)
          checkpoint_if_quackdb(started_repo)
          migrations
        end)
    end)

    :ok
  end

  defp checkpoint_if_quackdb(repo) do
    if Repo.adapter() == Ecto.Adapters.QuackDB do
      repo.query!("CHECKPOINT")
    end

    :ok
  end

  defp with_quackdb_server(fun) do
    if Repo.adapter() == Ecto.Adapters.QuackDB do
      run_with_quackdb_server(fun)
    else
      fun.()
    end
  end

  defp run_with_quackdb_server(fun) do
    case QuackDB.Server.start_link(LLMProxy.Config.quackdb_server_options()) do
      {:ok, pid} ->
        try do
          fun.()
        after
          if Process.alive?(pid), do: GenServer.stop(pid)
        end

      {:error, _reason} ->
        fun.()
    end
  end
end
