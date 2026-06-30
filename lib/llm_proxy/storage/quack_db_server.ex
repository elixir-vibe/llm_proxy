defmodule LLMProxy.Storage.QuackDBServer do
  @moduledoc """
  Starts the bundled QuackDB server and wires its generated token into the bundled Ecto repo.

  QuackDB owns local server token generation when no token is supplied. LLMProxy
  reads that generated token from the running server process and updates the
  bundled QuackDB repo configuration before the repo starts, avoiding an
  operator-managed `QUACKDB_TOKEN` secret.
  """

  alias LLMProxy.Storage.Repo.QuackDB, as: QuackDBRepo

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    with {:ok, pid} <- QuackDB.Server.start_link(server_options(options)) do
      configure_repo_from_server!(pid)
      {:ok, pid}
    end
  end

  @doc false
  @spec server_options(keyword()) :: keyword()
  def server_options(options) do
    Keyword.delete(options, :uri)
  end

  defp configure_repo_from_server!(pid) do
    update_repo_config(
      uri: QuackDB.Server.uri(pid),
      token: QuackDB.Server.token(pid)
    )
  end

  @doc false
  @spec update_repo_config(keyword()) :: :ok
  def update_repo_config(updates) do
    config = Application.get_env(:llm_proxy, QuackDBRepo, [])
    Application.put_env(:llm_proxy, QuackDBRepo, Keyword.merge(config, updates))
  end
end
