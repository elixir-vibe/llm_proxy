defmodule LLMProxy.Plugs.QuotaCheckTest do
  use ExUnit.Case

  import Plug.Test

  alias LLMProxy.Plugs.QuotaCheck
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
    :ok
  end

  test "passes requests within quota" do
    {:ok, key, _} = Storage.create_key("within-quota", %{quota_4h_input: 100})

    conn =
      conn(:get, "/")
      |> Plug.Conn.assign(:api_key, key)
      |> QuotaCheck.call([])

    refute conn.halted
  end

  test "halts requests that exceed quota" do
    {:ok, key, _} = Storage.create_key("limited", %{quota_4h_input: 100})

    Storage.record_usage(%{
      key_id: key.id,
      model: "test-model",
      input_tokens: 120,
      output_tokens: 0,
      timestamp: DateTime.utc_now()
    })

    conn =
      conn(:get, "/")
      |> Plug.Conn.assign(:api_key, key)
      |> QuotaCheck.call([])

    assert conn.halted
    assert conn.status == 429

    assert get_in(Jason.decode!(conn.resp_body), ["error", "message"]) =~
             "4h input quota exceeded"
  end

  test "bypasses quota checks for the master key" do
    conn =
      conn(:get, "/")
      |> Plug.Conn.assign(:api_key, %{id: "master"})
      |> QuotaCheck.call([])

    refute conn.halted
  end
end
