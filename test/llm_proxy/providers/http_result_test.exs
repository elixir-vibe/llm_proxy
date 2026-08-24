defmodule LLMProxy.Providers.HTTPResultTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.{HTTPResult, Result}
  alias LLMProxy.Schemas.ProviderTokenCooldown
  alias LLMProxy.Storage.Repo.SQLite

  describe "retry_after_ms/1" do
    test "parses retry-after seconds" do
      assert HTTPResult.retry_after_ms(%{"retry-after" => ["3"]}) == 3_000
    end

    test "ignores unsupported retry-after values" do
      assert HTTPResult.retry_after_ms(%{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]}) ==
               nil

      assert HTTPResult.retry_after_ms(%{}) == nil
    end
  end

  describe "handle_response/3" do
    setup do
      LLMProxy.TestSupport.checkout_repo()
      :ok = LLMProxy.TestSupport.allow_token_pool()
      LLMProxy.TestSupport.clear_provider_tokens()
      :ok
    end

    test "marks rate-limited tokens" do
      {:ok, token} = LLMProxy.Storage.add_token("openai", "api-key", "token")

      assert {:error, %Result{status: 429, token: ^token}} =
               HTTPResult.handle_response(token, 429, %{"error" => "slow down"})
    end

    test "limits a token only for the reported model" do
      {:ok, token} = LLMProxy.Storage.add_token("openai", "api-key", "token")

      assert {:error, %Result{status: 429, token: ^token}} =
               HTTPResult.handle_response(
                 token,
                 %{status: 429, body: %{"error" => "slow down"}, headers: %{}},
                 "model-a"
               )

      assert SQLite.get_by(ProviderTokenCooldown,
               token_id: token.id,
               model: "model-a"
             )

      refute SQLite.get_by(ProviderTokenCooldown,
               token_id: token.id,
               model: "*"
             )
    end

    test "keeps nil-token rate limits as provider errors" do
      assert {:error,
              %Result{
                status: 429,
                token: nil,
                provider_body: "slow down"
              }} =
               HTTPResult.handle_response(nil, 429, %{"error" => "slow down"})

      assert {:error,
              %Result{
                status: 429,
                token: nil,
                retry_after_ms: 3_000,
                provider_body: "slow down"
              }} =
               HTTPResult.handle_response(nil, %{
                 status: 429,
                 body: %{"error" => "slow down"},
                 headers: %{"retry-after" => ["3"]}
               })
    end
  end

  describe "handle_exception/1" do
    test "projects exceptions through the sanitized provider boundary" do
      assert {:error, result = %Result{status: 502, error: "boom"}} =
               HTTPResult.handle_exception(%RuntimeError{message: "boom"})

      assert Result.client_error(result)["message"] == "boom"
    end

    test "does not expose exception internals" do
      exception = RuntimeError.exception("request failed, headers: authorization=Bearer secret")
      assert {:error, result} = HTTPResult.handle_exception(exception)

      rendered = Jason.encode!(Result.client_error(result))
      refute rendered =~ "secret"
      refute rendered =~ "headers"
    end
  end

  describe "provider_details/1" do
    test "keeps only the upstream error payload when present" do
      body = %{"error" => %{"message" => "bad image"}, "user_id" => "provider-user"}
      assert HTTPResult.provider_details(body) == %{"message" => "bad image"}
    end
  end

  describe "extract/1" do
    test "extracts nested error message" do
      body = %{"error" => %{"message" => "Rate limit exceeded"}}
      assert HTTPResult.extract(body) == "Rate limit exceeded"
    end

    test "extracts string error" do
      body = %{"error" => "Something went wrong"}
      assert HTTPResult.extract(body) == "Something went wrong"
    end

    test "returns binary body as-is" do
      assert HTTPResult.extract("raw error text") == "raw error text"
    end

    test "uses a stable fallback for other values" do
      assert HTTPResult.extract(%{"status" => "fail"}) == "Upstream provider request failed"
      assert HTTPResult.extract(nil) == "Upstream provider request failed"
    end
  end
end
