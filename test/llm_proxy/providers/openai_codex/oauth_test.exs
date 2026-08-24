defmodule LLMProxy.Providers.OpenAICodex.OAuthTest do
  use ExUnit.Case

  alias LLMProxy.Provider.Credential
  alias LLMProxy.Provider.TokenCodec
  alias LLMProxy.Provider.TokenCodec.AESGCM
  alias LLMProxy.Providers.OpenAICodex.OAuth
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    previous_codec = Application.fetch_env(:llm_proxy, :provider_token_codec)

    on_exit(fn ->
      case previous_codec do
        {:ok, codec} -> Application.put_env(:llm_proxy, :provider_token_codec, codec)
        :error -> Application.delete_env(:llm_proxy, :provider_token_codec)
      end
    end)

    TestSupport.checkout_repo()
  end

  test "parses ReqLLM string-keyed refresh response into strict credentials" do
    expires = rounded_future_expires_ms()

    assert {:ok, %OAuth{} = credentials} =
             OAuth.from_refresh_response(%{
               "access" => "new-access",
               "refresh" => "new-refresh",
               "expires" => expires,
               "accountId" => "acct_123"
             })

    assert credentials.access == "new-access"
    assert credentials.refresh == "new-refresh"
    assert DateTime.to_unix(credentials.expires_at, :millisecond) == expires
    assert credentials.account_id == "acct_123"

    assert OAuth.storage_attrs(credentials) == %{
             token: "new-access",
             refresh_token: "new-refresh",
             expires_at: credentials.expires_at,
             account_id: "acct_123"
           }
  end

  test "rejects atom-keyed or incomplete refresh responses" do
    assert {:error, {:invalid_refresh_response, _reason}} =
             OAuth.from_refresh_response(%{
               access: "new-access",
               refresh: "new-refresh",
               expires: 1
             })

    assert {:error, message} =
             OAuth.from_refresh_response(%{
               "access" => "",
               "refresh" => "new-refresh",
               "expires" => 1
             })

    assert message =~ "access must be a non-empty string"
  end

  test "refreshes expired storage token and persists new credentials" do
    expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    refreshed_expires = rounded_future_expires_ms()

    {:ok, token} =
      Storage.add_token("openai-codex", "oauth", "old-access", %{
        refresh_token: "old-refresh",
        expires_at: expired,
        account_id: "acct_old"
      })

    refresh_fun = fn credentials, [] ->
      assert credentials == %{
               access: "old-access",
               refresh: "old-refresh",
               expires: DateTime.to_unix(expired, :millisecond)
             }

      {:ok,
       %{
         "access" => "new-access",
         "refresh" => "new-refresh",
         "expires" => refreshed_expires,
         "accountId" => "acct_new"
       }}
    end

    assert {:ok, updated} = OAuth.refresh_if_needed(token, refresh_fun)
    assert updated.token == "new-access"
    assert updated.refresh_token == "new-refresh"
    assert updated.account_id == "acct_new"
    assert DateTime.to_unix(updated.expires_at, :millisecond) == refreshed_expires
  end

  test "refreshes encrypted credentials and persists only ciphertext" do
    key = Base.encode64(:binary.copy(<<4>>, 32))

    Application.put_env(
      :llm_proxy,
      :provider_token_codec,
      {AESGCM, active_key_id: "v1", keys: %{"v1" => key}}
    )

    expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    refreshed_expires = rounded_future_expires_ms()

    assert {:ok, stored} =
             Storage.add_token("openai-codex", "oauth", "old-access", %{
               refresh_token: "old-refresh",
               expires_at: expired
             })

    refresh_fun = fn _credentials, [] ->
      {:ok,
       %{
         "access" => "new-access",
         "refresh" => "new-refresh",
         "expires" => refreshed_expires
       }}
    end

    assert {:ok, %Credential{token: "new-access", refresh_token: "new-refresh"}} =
             OAuth.refresh_if_needed(stored, refresh_fun)

    [encrypted] = Storage.list_tokens(%{provider: "openai-codex"})
    refute encrypted.token == "new-access"
    refute encrypted.refresh_token == "new-refresh"
    assert {:ok, "new-access"} = TokenCodec.decode(encrypted.token, :token)
    assert {:ok, "new-refresh"} = TokenCodec.decode(encrypted.refresh_token, :refresh_token)
  end

  test "leaves non-refreshable access tokens unchanged" do
    {:ok, token} = Storage.add_token("openai-codex", "oauth", "access-only")

    assert {:ok, ^token} =
             OAuth.refresh_if_needed(token, fn _credentials, _opts ->
               flunk("unexpected refresh")
             end)
  end

  defp rounded_future_expires_ms do
    DateTime.utc_now()
    |> DateTime.add(3_600, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_unix(:millisecond)
  end
end
