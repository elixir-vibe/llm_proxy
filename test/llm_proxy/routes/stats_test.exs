defmodule LLMProxy.Routes.StatsTest do
  use ExUnit.Case

  alias LLMProxy.Routes.Stats
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
    Application.put_env(:llm_proxy, :master_key, "master-key")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)
  end

  test "returns aggregate stats, daily stats, and messages" do
    {:ok, key, _} = Storage.create_key("stats-user")

    Storage.record_usage(%{
      key_id: key.id,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      cost_usd: 0.25,
      timestamp: DateTime.utc_now()
    })

    Storage.log_message(%{
      key_id: key.id,
      model: "gpt-4o",
      route: "chat",
      user_message: "hello",
      timestamp: DateTime.utc_now()
    })

    stats_conn =
      Plug.Test.conn(:get, "/")
      |> TestSupport.put_bearer("master-key")
      |> Stats.call(Stats.init([]))

    assert stats_conn.status == 200
    assert Jason.decode!(stats_conn.resp_body)["total_requests"] == 1

    daily_conn =
      Plug.Test.conn(:get, "/daily?key_id=#{key.id}")
      |> TestSupport.put_bearer("master-key")
      |> Stats.call(Stats.init([]))

    assert daily_conn.status == 200
    assert [daily_entry] = Jason.decode!(daily_conn.resp_body)
    assert daily_entry["requests"] == 1

    messages_conn =
      Plug.Test.conn(:get, "/messages?keyId=#{key.id}&limit=5&offset=0")
      |> TestSupport.put_bearer("master-key")
      |> Stats.call(Stats.init([]))

    assert messages_conn.status == 200
    assert [message] = Jason.decode!(messages_conn.resp_body)
    assert message["user_message"] == "hello"
  end
end
