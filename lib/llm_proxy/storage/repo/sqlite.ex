if Code.ensure_loaded?(Ecto.Adapters.SQLite3) do
  defmodule LLMProxy.Storage.Repo.SQLite do
    @moduledoc """
    Bundled SQLite Ecto repo for local development, tests, and standalone storage.
    """

    use Ecto.Repo,
      otp_app: :llm_proxy,
      adapter: Ecto.Adapters.SQLite3,
      priv: "priv/repo"
  end
end
