defmodule LLMProxy.Storage.RepoTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Storage.Repo

  defmodule HostRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3
    def config, do: [database: "host.db"]
  end

  setup do
    original = Application.get_env(:llm_proxy, :repo)

    on_exit(fn ->
      if original do
        Application.put_env(:llm_proxy, :repo, original)
      else
        Application.delete_env(:llm_proxy, :repo)
      end
    end)
  end

  test "defaults to bundled repo" do
    Application.delete_env(:llm_proxy, :repo)

    assert Repo.configured() == LLMProxy.Storage.Repo.SQLite
    assert Repo.bundled?()
  end

  test "delegates metadata to configured host repo" do
    Application.put_env(:llm_proxy, :repo, HostRepo)

    assert Repo.configured() == HostRepo
    refute Repo.bundled?()
    assert Repo.adapter() == Ecto.Adapters.SQLite3
    assert Repo.config() == [database: "host.db"]
  end
end
