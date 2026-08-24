defmodule LLMProxy.Provider.TokenCodec.AESGCMTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Provider.TokenCodec.AESGCM

  @key_v1 Base.encode64(:binary.copy(<<1>>, 32))
  @key_v2 Base.encode64(:binary.copy(<<2>>, 32))

  test "writes the active version and reads prior versions" do
    assert {:ok, ciphertext_v1} = AESGCM.encode("seeded-secret", context(:token), options("v1"))
    assert String.starts_with?(ciphertext_v1, "llm_proxy:token:v1:v1:")
    refute ciphertext_v1 =~ "seeded-secret"

    assert {:ok, "seeded-secret"} = AESGCM.decode(ciphertext_v1, context(:token), options("v2"))
    assert {:ok, ciphertext_v2} = AESGCM.encode("seeded-secret", context(:token), options("v2"))
    assert String.starts_with?(ciphertext_v2, "llm_proxy:token:v1:v2:")
  end

  test "binds ciphertext to its credential field" do
    assert {:ok, ciphertext} =
             AESGCM.encode("refresh-secret", context(:refresh_token), options("v2"))

    assert {:error, :authentication_failed} =
             AESGCM.decode(ciphertext, context(:token), options("v2"))

    assert {:ok, "refresh-secret"} =
             AESGCM.decode(ciphertext, context(:refresh_token), options("v2"))
  end

  test "authenticates the key identifier in the envelope" do
    shared_key = Base.encode64(:binary.copy(<<3>>, 32))
    options = [active_key_id: "v1", keys: %{"v1" => shared_key, "v2" => shared_key}]

    assert {:ok, ciphertext} = AESGCM.encode("seeded-secret", context(:token), options)

    tampered =
      String.replace_prefix(ciphertext, "llm_proxy:token:v1:v1:", "llm_proxy:token:v1:v2:")

    assert {:error, :authentication_failed} = AESGCM.decode(tampered, context(:token), options)
  end

  test "can reject legacy plaintext after migration" do
    options = Keyword.put(options("v2"), :allow_plaintext, false)
    assert {:error, :plaintext_not_allowed} = AESGCM.decode("legacy", context(:token), options)
  end

  test "validates every key and the active write key" do
    assert :ok = AESGCM.validate_options(options("v2"))

    assert {:error, _reason} =
             AESGCM.validate_options(active_key_id: "missing", keys: %{"v1" => @key_v1})

    assert {:error, _reason} =
             AESGCM.validate_options(
               active_key_id: "v1",
               keys: %{"v1" => @key_v1, "old" => "invalid"}
             )
  end

  defp context(field), do: %{field: field}

  defp options(active_key_id) do
    [active_key_id: active_key_id, keys: %{"v1" => @key_v1, "v2" => @key_v2}]
  end
end
