defmodule LLMProxy.Provider.TokenCodecTest do
  use ExUnit.Case, async: false

  alias LLMProxy.Provider.Credential
  alias LLMProxy.Provider.TokenCodec
  alias LLMProxy.Provider.TokenCodec.AESGCM
  alias LLMProxy.Providers.Result
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server

  @key_v1 Base.encode64(:binary.copy(<<1>>, 32))
  @key_v2 Base.encode64(:binary.copy(<<2>>, 32))

  defmodule ReverseCodec do
    @behaviour LLMProxy.Provider.TokenCodec

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

  defmodule LeakyCodec do
    @behaviour LLMProxy.Provider.TokenCodec

    @impl true
    def encode(value, _context, _options), do: raise("failed with #{value}")

    @impl true
    def decode(value, _context, _options), do: {:error, {:secret, value}}

    @impl true
    def encoded?(_value, _options), do: false
  end

  defmodule InvalidCodec do
    @behaviour LLMProxy.Provider.TokenCodec

    @impl true
    def validate_options(_options), do: {:error, {:seeded_secret, "must-not-escape"}}

    @impl true
    def encode(value, _context, _options), do: {:ok, value}

    @impl true
    def decode(value, _context, _options), do: {:ok, value}

    @impl true
    def encoded?(_value, _options), do: false
  end

  setup do
    previous =
      Map.new(
        [:provider_token_codec, :provider_token_keyring, :provider_token_allow_plaintext],
        fn key ->
          {key, Application.fetch_env(:llm_proxy, key)}
        end
      )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:llm_proxy, key, value)
        {key, :error} -> Application.delete_env(:llm_proxy, key)
      end)
    end)

    :ok
  end

  test "a custom codec works without provider changes" do
    checkout_token_storage()
    Application.put_env(:llm_proxy, :provider_token_codec, {ReverseCodec, prefix: "custom:"})

    assert {:ok, stored} = Storage.add_token("openai", "api-key", "custom-secret")
    assert stored.token == "custom:token:terces-motsuc"

    assert {:ok, %Credential{token: "custom-secret"}} =
             Server.pick_token_by_kind("openai", "api-key", "user")
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

    assert {:ok, %Credential{} = credential} =
             Server.pick_token_by_kind("openai-codex", "oauth", "user")

    assert credential.token == "access-seeded-secret"
    assert credential.refresh_token == "refresh-seeded-secret"
    refute inspect(credential) =~ "seeded-secret"
    refute inspect(Result.response(%{}, credential)) =~ "seeded-secret"
  end

  test "plaintext storage also produces a redacted request-scoped credential" do
    checkout_token_storage()
    Application.put_env(:llm_proxy, :provider_token_codec, TokenCodec.Plaintext)

    assert {:ok, _stored} = Storage.add_token("openai", "api-key", "plaintext-secret")

    assert {:ok, %Credential{token: "plaintext-secret"}} =
             Server.pick_token_by_kind("openai", "api-key", "user")
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
        {:ok, credential} = TokenCodec.credential(stored)
        credential.token
      end)

    assert Enum.sort(credentials) == ["existing-secret", "new-secret"]
  end

  test "missing keyring configuration fails closed without crashing the token pool" do
    checkout_token_storage()
    configure_aes("v2")
    assert {:ok, stored} = Storage.add_token("openai", "api-key", "seeded-secret")

    Application.delete_env(:llm_proxy, :provider_token_codec)
    Application.delete_env(:llm_proxy, :provider_token_keyring)
    Application.put_env(:llm_proxy, :provider_token_allow_plaintext, true)

    assert TokenCodec.encoded?(stored.token)

    assert {:error, {:provider_token_codec, :encrypted_value_requires_keyring}} =
             Server.pick_token_by_kind("openai", "api-key", "user")

    assert Process.alive?(Process.whereis(Server))
  end

  test "invalid active key configuration is rejected before use" do
    Application.delete_env(:llm_proxy, :provider_token_codec)

    Application.put_env(:llm_proxy, :provider_token_keyring, %{
      "active_key_id" => "missing",
      "keys" => %{"v1" => @key_v1}
    })

    assert {:error, :invalid_codec_options} = TokenCodec.validate_configuration()
  end

  test "custom codec failures are reduced to a bounded reason" do
    Application.put_env(:llm_proxy, :provider_token_codec, LeakyCodec)

    assert {:error, :codec_failed} = TokenCodec.encode("seeded-secret", :token)
    assert {:error, :codec_failed} = TokenCodec.decode("seeded-secret", :token)
    refute inspect(TokenCodec.encode("seeded-secret", :token)) =~ "seeded-secret"
  end

  test "custom codec validation errors are reduced to a bounded reason" do
    Application.put_env(:llm_proxy, :provider_token_codec, InvalidCodec)

    assert {:error, :invalid_codec_options} = TokenCodec.validate_configuration()
    refute inspect(TokenCodec.validate_configuration()) =~ "must-not-escape"
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
