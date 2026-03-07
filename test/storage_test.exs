defmodule LLMProxy.StorageTest do
  use ExUnit.Case

  alias LLMProxy.Storage
  alias LLMProxy.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "API keys" do
    test "create and find key" do
      {:ok, key, raw_key} = Storage.create_key("test-user")

      assert key.name == "test-user"
      assert key.input_tokens == 0

      found = Storage.find_key(raw_key)
      assert found.id == key.id
    end

    test "find_key returns nil for unknown key" do
      assert Storage.find_key("sk-proxy-nonexistent") == nil
    end

    test "list_keys returns all keys" do
      {:ok, _k1, _} = Storage.create_key("user-1")
      {:ok, _k2, _} = Storage.create_key("user-2")

      keys = Storage.list_keys()
      assert length(keys) == 2
    end

    test "delete_key removes key and usage" do
      {:ok, key, _} = Storage.create_key("deletable")

      Storage.record_usage(%{
        key_id: key.id,
        model: "test",
        input_tokens: 100,
        output_tokens: 50,
        timestamp: DateTime.utc_now()
      })

      {:ok, _} = Storage.delete_key(key.id)
      assert Storage.list_keys() == []
    end

    test "check_model_access with nil allowed_models allows everything" do
      {:ok, key, _} = Storage.create_key("open")
      assert :ok == Storage.check_model_access(key, "any-model")
    end

    test "check_model_access with restricted models" do
      {:ok, key, _} = Storage.create_key("restricted", %{allowed_models: ["model-a"]})

      assert :ok == Storage.check_model_access(key, "model-a")
      assert {:error, _} = Storage.check_model_access(key, "model-b")
    end
  end

  describe "quota checking" do
    test "no quotas means always allowed" do
      {:ok, key, _} = Storage.create_key("no-quota")
      assert :ok == Storage.check_quota(key)
    end

    test "4h input quota exceeded" do
      {:ok, key, _} = Storage.create_key("limited", %{quota_4h_input: 1000})

      Storage.record_usage(%{
        key_id: key.id,
        model: "test",
        input_tokens: 1500,
        output_tokens: 0,
        timestamp: DateTime.utc_now()
      })

      assert {:error, msg} = Storage.check_quota(key)
      assert msg =~ "4h input quota exceeded"
    end

    test "weekly output quota exceeded" do
      {:ok, key, _} = Storage.create_key("weekly", %{quota_week_output: 500})

      Storage.record_usage(%{
        key_id: key.id,
        model: "test",
        input_tokens: 0,
        output_tokens: 600,
        timestamp: DateTime.utc_now()
      })

      assert {:error, msg} = Storage.check_quota(key)
      assert msg =~ "Weekly output quota exceeded"
    end

    test "message quota exceeded" do
      {:ok, key, _} = Storage.create_key("msg-limited", %{quota_4h_messages: 2})

      for _ <- 1..3 do
        Storage.record_usage(%{
          key_id: key.id,
          model: "test",
          input_tokens: 10,
          output_tokens: 10,
          timestamp: DateTime.utc_now()
        })
      end

      assert {:error, msg} = Storage.check_quota(key)
      assert msg =~ "4h message quota exceeded"
    end
  end

  describe "provider tokens" do
    test "add, list, and remove tokens" do
      {:ok, token} = Storage.add_token("anthropic", "oauth", "tok-123")

      assert token.provider == "anthropic"
      assert token.kind == "oauth"
      assert token.enabled == true

      tokens = Storage.get_tokens("anthropic", "oauth")
      assert length(tokens) == 1

      {:ok, _} = Storage.remove_token(token.id)
      assert Storage.get_tokens("anthropic", "oauth") == []
    end

    test "disable token excludes from get_tokens" do
      {:ok, token} = Storage.add_token("openrouter", "api-key", "key-abc")
      {:ok, _} = Storage.set_token_enabled(token.id, false)

      assert Storage.get_tokens("openrouter", "api-key") == []
    end
  end
end
