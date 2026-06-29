defmodule LLMProxy.Providers.OpenAICodex.OAuth.LoginTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.OpenAICodex.OAuth
  alias LLMProxy.Providers.OpenAICodex.OAuth.Login

  test "authorization URL uses Codex OAuth parameters" do
    url = Login.authorize_url("challenge", "state", "test-origin")
    uri = URI.parse(url)
    params = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "auth.openai.com"
    assert uri.path == "/oauth/authorize"
    assert params["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
    assert params["redirect_uri"] == "http://localhost:1455/auth/callback"
    assert params["scope"] == "openid profile email offline_access"
    assert params["code_challenge"] == "challenge"
    assert params["code_challenge_method"] == "S256"
    assert params["state"] == "state"
    assert params["id_token_add_organizations"] == "true"
    assert params["codex_cli_simplified_flow"] == "true"
    assert params["originator"] == "test-origin"
  end

  test "parses pasted authorization inputs" do
    assert Login.parse_authorization_input("plain-code", "state") == {:ok, "plain-code"}
    assert Login.parse_authorization_input("code=abc&state=state", "state") == {:ok, "abc"}

    assert Login.parse_authorization_input(
             "http://localhost:1455/auth/callback?code=abc&state=state",
             "state"
           ) == {:ok, "abc"}

    assert Login.parse_authorization_input("code=abc&state=other", "state") ==
             {:error, :state_mismatch}
  end

  test "parses token response into strict OAuth credentials" do
    expires_before = System.system_time(:millisecond) |> div(1000) |> Kernel.*(1000)
    jwt = account_jwt("acct_123")

    assert {:ok, %OAuth{} = credentials} =
             Login.parse_token_response(%{
               "access_token" => jwt,
               "refresh_token" => "refresh-token",
               "expires_in" => 3600
             })

    assert credentials.access == jwt
    assert credentials.refresh == "refresh-token"
    assert credentials.account_id == "acct_123"
    assert DateTime.to_unix(credentials.expires_at, :millisecond) >= expires_before + 3_600_000
  end

  test "exchanges authorization code with expected token request" do
    jwt = account_jwt("acct_456")

    post_fun = fn url, opts ->
      assert url == "https://auth.openai.com/oauth/token"
      assert opts[:headers] == [{"content-type", "application/x-www-form-urlencoded"}]

      params = URI.decode_query(opts[:body])
      assert params["grant_type"] == "authorization_code"
      assert params["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
      assert params["code"] == "code-123"
      assert params["code_verifier"] == "verifier-123"
      assert params["redirect_uri"] == "http://localhost:1455/auth/callback"

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "access_token" => jwt,
           "refresh_token" => "refresh-token",
           "expires_in" => 3600
         }
       }}
    end

    assert {:ok, credentials} = Login.exchange_code("code-123", "verifier-123", post_fun)
    assert credentials.account_id == "acct_456"
  end

  test "extracts account id from access-token JWT" do
    assert Login.account_id(account_jwt("acct_789")) == "acct_789"
    assert Login.account_id("not-a-jwt") == nil
  end

  defp account_jwt(account_id) do
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)

    payload =
      %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    header <> "." <> payload <> ".signature"
  end
end
