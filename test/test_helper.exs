Code.require_file("../test_support/support.ex", __DIR__)
Code.require_file("../test_support/req_stubs.ex", __DIR__)

unless Code.ensure_loaded?(Ecto.Adapters.QuackDB) do
  defmodule Ecto.Adapters.QuackDB do
  end
end

Ecto.Adapters.SQL.Sandbox.mode(LLMProxy.Storage.Repo.SQLite, :manual)
ExUnit.start(exclude: [:integration])
