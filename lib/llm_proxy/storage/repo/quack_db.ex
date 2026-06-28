if Code.ensure_loaded?(Ecto.Adapters.QuackDB) do
  defmodule LLMProxy.Storage.Repo.QuackDB do
    @moduledoc """
    Bundled QuackDB Ecto repo for production DuckDB-backed storage.
    """

    use Ecto.Repo,
      otp_app: :llm_proxy,
      adapter: Ecto.Adapters.QuackDB,
      priv: "priv/repo"
  end
end
