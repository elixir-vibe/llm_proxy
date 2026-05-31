defmodule LLMProxy.HTTP.Routes.TokensTest do
  use ExUnit.Case

  alias LLMProxy.HTTP.Routes.Tokens
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    Application.put_env(:llm_proxy, :master_key, "master-key")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)
  end

  test "lists, creates, updates, clears, and deletes tokens" do
    created =
      TestSupport.json_conn(:post, "/", %{
        "provider" => "openai",
        "kind" => "api-key",
        "token" => "secret-token-123456",
        "label" => "primary"
      })
      |> TestSupport.put_bearer("master-key")
      |> Tokens.call(Tokens.init([]))

    assert created.status == 200
    token_id = Jason.decode!(created.resp_body)["id"]

    list_conn =
      Plug.Test.conn(:get, "/?provider=openai")
      |> Plug.Conn.fetch_query_params()
      |> TestSupport.put_bearer("master-key")
      |> Tokens.call(Tokens.init([]))

    assert list_conn.status == 200
    assert [%{"provider" => "openai"}] = Jason.decode!(list_conn.resp_body)

    patch_conn =
      TestSupport.json_conn(:patch, "/#{token_id}", %{
        "enabled" => false,
        "proxy" => "http://proxy"
      })
      |> TestSupport.put_bearer("master-key")
      |> Tokens.call(Tokens.init([]))

    assert patch_conn.status == 200

    assert Jason.decode!(patch_conn.resp_body) == %{
             "enabled" => false,
             "id" => token_id,
             "proxy" => "http://proxy"
           }

    clear_conn =
      TestSupport.json_conn(:post, "/clear-rate-limits", %{})
      |> TestSupport.put_bearer("master-key")
      |> Tokens.call(Tokens.init([]))

    assert clear_conn.status == 200
    assert Jason.decode!(clear_conn.resp_body) == %{"cleared" => true}

    delete_conn =
      Plug.Test.conn(:delete, "/#{token_id}")
      |> TestSupport.put_bearer("master-key")
      |> Tokens.call(Tokens.init([]))

    assert delete_conn.status == 200
    assert Jason.decode!(delete_conn.resp_body) == %{"deleted" => true}
    assert Storage.list_tokens() == []
  end

  test "validates bad requests and missing tokens" do
    missing_fields =
      TestSupport.json_conn(:post, "/", %{"provider" => "openai"})
      |> TestSupport.put_bearer("master-key")
      |> Tokens.call(Tokens.init([]))

    assert missing_fields.status == 400

    patch_missing =
      TestSupport.json_conn(:patch, "/999", %{"enabled" => false})
      |> TestSupport.put_bearer("master-key")
      |> Tokens.call(Tokens.init([]))

    assert patch_missing.status == 404

    delete_missing =
      Plug.Test.conn(:delete, "/999")
      |> TestSupport.put_bearer("master-key")
      |> Tokens.call(Tokens.init([]))

    assert delete_missing.status == 404
  end
end
