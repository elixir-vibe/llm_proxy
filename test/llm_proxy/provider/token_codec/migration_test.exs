defmodule LLMProxy.Provider.TokenCodec.MigrationTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Provider.TokenCodec
  alias LLMProxy.Provider.TokenCodec.AESGCM
  alias LLMProxy.Provider.TokenCodec.Migration
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server

  @key_v1 Base.encode64(:binary.copy(<<1>>, 32))
  @key_v2 Base.encode64(:binary.copy(<<2>>, 32))

  setup do
    previous = Application.fetch_env(:llm_proxy, :provider_token_codec)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:llm_proxy, :provider_token_codec, value)
        :error -> Application.delete_env(:llm_proxy, :provider_token_codec)
      end
    end)

    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    Server.clear_rate_limits()
    :ok
  end

  test "plaintext migration is explicit, verified, and reversible" do
    Application.put_env(:llm_proxy, :provider_token_codec, TokenCodec.Plaintext)

    assert {:ok, _stored} =
             Storage.add_token("openai-codex", "oauth", "legacy-access", %{
               refresh_token: "legacy-refresh"
             })

    configure_aes("v2")
    assert {:ok, %{plaintext_fields: 2, encrypted_fields: 0}} = Migration.status()
    assert {:ok, %{changed_rows: 1, changed_fields: 2}} = Migration.encrypt_all()
    assert {:ok, %{plaintext_fields: 0, encrypted_fields: 2}} = Migration.verify()

    [encrypted] = Storage.list_tokens()
    refute encrypted.token == "legacy-access"
    refute encrypted.refresh_token == "legacy-refresh"

    assert {:ok, %{changed_rows: 1, changed_fields: 2}} = Migration.decrypt_all()
    assert [%{token: "legacy-access", refresh_token: "legacy-refresh"}] = Storage.list_tokens()
  end

  test "rotation re-encrypts stored values with the active key" do
    configure_aes("v1")
    assert {:ok, stored} = Storage.add_token("openai", "api-key", "rotate-secret")
    assert String.starts_with?(stored.token, "llm_proxy:token:v1:v1:")

    configure_aes("v2")
    assert {:ok, %{changed_rows: 1, changed_fields: 1}} = Migration.rotate_all()
    assert [rotated] = Storage.list_tokens()
    assert String.starts_with?(rotated.token, "llm_proxy:token:v1:v2:")
    assert {:ok, %{encrypted_fields: 1, plaintext_fields: 0}} = Migration.verify()
  end

  test "status rejects invalid codec configuration" do
    Application.put_env(
      :llm_proxy,
      :provider_token_codec,
      {AESGCM, active_key_id: "missing", keys: %{}}
    )

    assert {:error, :invalid_codec_options} = Migration.status()
  end

  defp configure_aes(active_key_id) do
    Application.put_env(
      :llm_proxy,
      :provider_token_codec,
      {AESGCM, active_key_id: active_key_id, keys: %{"v1" => @key_v1, "v2" => @key_v2}}
    )
  end
end
