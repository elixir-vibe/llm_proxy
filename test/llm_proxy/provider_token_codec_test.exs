defmodule LLMProxy.ProviderTokenCodecTest do
  use ExUnit.Case

  alias LLMProxy.ProviderCredential
  alias LLMProxy.Providers.Result
  alias LLMProxy.ProviderTokenCodec
  alias LLMProxy.ProviderTokenCodec.AESGCM
  alias LLMProxy.ProviderTokenCodec.Migration
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server

  @key_v1 Base.encode64(:binary.copy(<<1>>, 32))
  @key_v2 Base.encode64(:binary.copy(<<2>>, 32))

  defmodule ReverseCodec do
    @behaviour LLMProxy.ProviderTokenCodec

    @impl true
    def encode(value, %{field: field}, options) do
      prefix = option(options, :prefix)
      {:ok, prefix <> Atom.to_string(field) <> ":" <> String.reverse(value)}
    end

    @impl true
    def decode(value, %{field: field}, options) do
      prefix = option(options, :prefix) <> Atom.to_string(field) <> ":"
      {:ok, value |> String.replace_prefix(prefix, "") |> String.reverse()}
    end

    @impl true
    def encoded?(value, options), do: String.starts_with?(value, option(options, :prefix))

    defp option(options, key) when is_list(options), do: Keyword.fetch!(options, key)
    defp option(options, key) when is_map(options), do: Map.fetch!(options, key)
  end

  setup do
    previous = Application.get_env(:llm_proxy, :provider_token_codec)

    on_exit(fn ->
      if previous do
        Application.put_env(:llm_proxy, :provider_token_codec, previous)
      else
        Application.delete_env(:llm_proxy, :provider_token_codec)
      end
    end)

    :ok
  end

  test "AES-GCM writes the active version and reads prior versions" do
    configure_aes("v1")
    assert {:ok, ciphertext_v1} = ProviderTokenCodec.encode("seeded-secret", :token)
    assert String.starts_with?(ciphertext_v1, "llm_proxy:token:v1:v1:")
    refute ciphertext_v1 =~ "seeded-secret"

    configure_aes("v2")
    assert {:ok, "seeded-secret"} = ProviderTokenCodec.decode(ciphertext_v1, :token)
    assert {:ok, ciphertext_v2} = ProviderTokenCodec.encode("seeded-secret", :token)
    assert String.starts_with?(ciphertext_v2, "llm_proxy:token:v1:v2:")
  end

  test "AES-GCM binds ciphertext to its credential field" do
    configure_aes("v2")
    assert {:ok, ciphertext} = ProviderTokenCodec.encode("refresh-secret", :refresh_token)
    assert {:error, :authentication_failed} = ProviderTokenCodec.decode(ciphertext, :token)
    assert {:ok, "refresh-secret"} = ProviderTokenCodec.decode(ciphertext, :refresh_token)
  end

  test "AES-GCM can reject legacy plaintext after migration" do
    configure_aes("v2", allow_plaintext: false)
    assert {:error, :plaintext_not_allowed} = ProviderTokenCodec.decode("legacy", :token)
  end

  test "a custom codec works without provider changes" do
    checkout_token_storage()

    Application.put_env(
      :llm_proxy,
      :provider_token_codec,
      {ReverseCodec, prefix: "custom:"}
    )

    assert {:ok, stored} = Storage.add_token("openai", "api-key", "custom-secret")
    assert stored.token == "custom:token:terces-motsuc"

    assert {:ok, %ProviderCredential{} = credential} =
             Server.pick_token_by_kind("openai", "api-key", "user")

    assert credential.token == "custom-secret"
  end

  test "encrypted storage and runtime values redact seeded secrets" do
    checkout_token_storage()
    configure_aes("v2")

    assert {:ok, stored} =
             Storage.add_token("openai-codex", "oauth", "access-seeded-secret", %{
               refresh_token: "refresh-seeded-secret"
             })

    assert String.starts_with?(stored.token, "llm_proxy:token:v1:v2:")
    assert String.starts_with?(stored.refresh_token, "llm_proxy:token:v1:v2:")
    refute inspect(stored) =~ "seeded-secret"
    refute inspect(Storage.list_tokens()) =~ "seeded-secret"

    assert {:ok, credential} = Server.pick_token_by_kind("openai-codex", "oauth", "user")
    assert credential.token == "access-seeded-secret"
    assert credential.refresh_token == "refresh-seeded-secret"
    refute inspect(credential) =~ "seeded-secret"
    refute inspect(Result.response(%{}, credential)) =~ "seeded-secret"
  end

  test "encrypted environment seeding does not add duplicates" do
    checkout_token_storage()
    configure_aes("v2")

    assert {:ok, _stored} = Storage.add_token("openai", "api-key", "existing-secret")

    assert :ok =
             Storage.seed_tokens_from_env([
               %{
                 provider: "openai",
                 kind: "api-key",
                 tokens: ["existing-secret", "new-secret"]
               }
             ])

    credentials =
      "openai"
      |> Storage.get_tokens("api-key")
      |> Enum.map(fn stored ->
        {:ok, credential} = ProviderTokenCodec.credential(stored)
        credential.token
      end)

    assert Enum.sort(credentials) == ["existing-secret", "new-secret"]
  end

  test "plaintext migration is explicit, verified, and reversible" do
    checkout_token_storage()
    Application.put_env(:llm_proxy, :provider_token_codec, LLMProxy.ProviderTokenCodec.Plaintext)

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
    checkout_token_storage()
    configure_aes("v1")
    assert {:ok, stored} = Storage.add_token("openai", "api-key", "rotate-secret")
    assert String.starts_with?(stored.token, "llm_proxy:token:v1:v1:")

    configure_aes("v2")
    assert {:ok, %{changed_rows: 1, changed_fields: 1}} = Migration.rotate_all()
    assert [rotated] = Storage.list_tokens()
    assert String.starts_with?(rotated.token, "llm_proxy:token:v1:v2:")
    assert {:ok, %{encrypted_fields: 1, plaintext_fields: 0}} = Migration.verify()
  end

  defp checkout_token_storage do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    Server.clear_rate_limits()
  end

  defp configure_aes(active_key_id, extra \\ []) do
    options =
      Keyword.merge(
        [active_key_id: active_key_id, keys: %{"v1" => @key_v1, "v2" => @key_v2}],
        extra
      )

    Application.put_env(:llm_proxy, :provider_token_codec, {AESGCM, options})
  end
end
