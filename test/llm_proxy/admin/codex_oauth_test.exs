if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.CodexOAuthTest do
    use ExUnit.Case, async: false

    @moduletag :incant

    alias Incant.ActionResult
    alias LLMProxy.Admin.CodexOAuth
    alias LLMProxy.Providers.OpenAICodex.OAuth

    setup do
      LLMProxy.TestSupport.checkout_repo()
    end

    test "starts OAuth authorization" do
      assert %ActionResult.Job{id: "codex_oauth", meta: %{"oauth" => oauth}} =
               CodexOAuth.start(%{}, %{})

      assert %{
               "authorization_url" => authorization_url,
               "state" => state,
               "verifier" => verifier
             } = oauth

      assert authorization_url =~ "https://auth.openai.com/oauth/authorize"
      assert authorization_url =~ URI.encode_query(%{state: state})
      assert is_binary(verifier)
    end

    test "stores OAuth credentials" do
      {:ok, credentials} =
        OAuth.new(
          "access-token",
          "refresh-token",
          DateTime.utc_now() |> DateTime.add(3600, :second),
          "account-123"
        )

      assert {:ok, token} = CodexOAuth.store_credentials(credentials)

      assert token.provider == "openai-codex"
      assert token.kind == "oauth"
      assert token.token == "access-token"
      assert token.refresh_token == "refresh-token"
      assert token.account_id == "account-123"
      assert token.label == "codex-login"
    end
  end
end
