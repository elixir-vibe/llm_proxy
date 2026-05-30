Code.require_file("../test_support/support.ex", __DIR__)
Code.require_file("../test_support/req_stubs.ex", __DIR__)

Ecto.Adapters.SQL.Sandbox.mode(LLMProxy.Repo, :manual)
ExUnit.start(exclude: [:integration])
