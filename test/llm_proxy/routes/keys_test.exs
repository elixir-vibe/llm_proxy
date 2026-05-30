defmodule LLMProxy.Routes.KeysTest do
  use ExUnit.Case

  alias LLMProxy.Routes.Keys
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
    Application.put_env(:llm_proxy, :master_key, "master-key")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)
  end

  test "returns self-service usage for an api key" do
    {:ok, key, raw_key} = Storage.create_key("usage-user", %{quota_4h_input: 1000})

    Storage.record_usage(%{
      key_id: key.id,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      timestamp: DateTime.utc_now()
    })

    conn =
      Plug.Test.conn(:get, "/usage")
      |> TestSupport.put_bearer(raw_key)
      |> Keys.call(Keys.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "usage-user"
    assert body["usage_4h"]["input"] == 10
    assert body["quota_4h_input"] == 1000
  end

  test "generates, updates, and deletes keys with the master key" do
    generated =
      TestSupport.json_conn(:post, "/generate", %{
        "name" => "generated",
        "quota_4h_input" => 50,
        "budget_limits" => [%{"metric" => "requests", "window" => "1h", "max" => 10}]
      })
      |> TestSupport.put_bearer("master-key")
      |> Keys.call(Keys.init([]))

    assert generated.status == 200
    generated_body = Jason.decode!(generated.resp_body)
    key_id = generated_body["id"]
    assert generated_body["name"] == "generated"

    assert generated_body["budget_limits"] == [
             %{"metric" => "requests", "window" => "hour", "max" => 10}
           ]

    updated_quota =
      TestSupport.json_conn(:post, "/quota", %{"id" => key_id, "quota_4h_output" => 75})
      |> TestSupport.put_bearer("master-key")
      |> Keys.call(Keys.init([]))

    assert updated_quota.status == 200

    updated_models =
      TestSupport.json_conn(:post, "/models", %{"id" => key_id, "allowed_models" => ["gpt-4o"]})
      |> TestSupport.put_bearer("master-key")
      |> Keys.call(Keys.init([]))

    assert updated_models.status == 200

    show =
      Plug.Test.conn(:get, "/#{key_id}")
      |> TestSupport.put_bearer("master-key")
      |> Keys.call(Keys.init([]))

    assert show.status == 200
    assert Jason.decode!(show.resp_body)["allowed_models"] == ["gpt-4o"]

    deleted =
      TestSupport.json_conn(:post, "/delete", %{"id" => key_id})
      |> TestSupport.put_bearer("master-key")
      |> Keys.call(Keys.init([]))

    assert deleted.status == 200

    missing =
      Plug.Test.conn(:get, "/#{key_id}")
      |> TestSupport.put_bearer("master-key")
      |> Keys.call(Keys.init([]))

    assert missing.status == 404
  end
end
