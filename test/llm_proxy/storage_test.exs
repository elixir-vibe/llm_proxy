defmodule LLMProxy.StorageTest do
  use ExUnit.Case

  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo.SQLite

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(SQLite)
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

    test "validates quota and budget attrs" do
      assert {:error, changeset} =
               Storage.create_key("invalid", %{
                 quota_4h_input: -1,
                 min_cache_ratio: 1.5,
                 max_budget_usd: -10.0,
                 budget_period: "month",
                 budget_limits: [%{"metric" => "nope", "window" => "24h", "max" => 1}]
               })

      assert changeset.errors[:quota_4h_input]
      assert changeset.errors[:min_cache_ratio]
      assert changeset.errors[:max_budget_usd]
      assert changeset.errors[:budget_period]
      assert changeset.errors[:budget_limits]
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

  describe "budget and cache ratio" do
    test "composable budget limits are enforced" do
      {:ok, key, _} =
        Storage.create_key("budget-limits", %{
          budget_limits: [
            LLMProxy.Limit.cost(:day, 1.0),
            LLMProxy.Limit.requests(:hour, 10)
          ]
        })

      Storage.record_usage(%{
        key_id: key.id,
        model: "test",
        input_tokens: 10,
        output_tokens: 5,
        cost_usd: 1.5,
        timestamp: DateTime.utc_now()
      })

      assert {:error, msg} = Storage.check_quota(key)
      assert msg =~ "cost_usd limit exceeded for day"
    end

    test "budget and cache ratio checks are enforced" do
      {:ok, key, _} =
        Storage.create_key("budgeted", %{
          max_budget_usd: 1.0,
          budget_period: "4h",
          min_cache_ratio: 0.5
        })

      Storage.record_usage(%{
        key_id: key.id,
        model: "test",
        input_tokens: 60_000,
        output_tokens: 0,
        cache_read_tokens: 0,
        cost_usd: 1.1,
        timestamp: DateTime.utc_now()
      })

      assert {:error, msg} = Storage.check_quota(key)
      assert msg =~ "Budget exceeded"

      {:ok, cache_key, _} = Storage.create_key("cachey", %{min_cache_ratio: 0.6})

      Storage.record_usage(%{
        key_id: cache_key.id,
        model: "test",
        input_tokens: 60_000,
        output_tokens: 0,
        cache_read_tokens: 10_000,
        timestamp: DateTime.utc_now()
      })

      assert {:error, cache_msg} = Storage.check_quota(cache_key)
      assert cache_msg =~ "Cache hit ratio too low"
    end
  end

  describe "service quotas" do
    test "checks service usage in rolling windows" do
      {:ok, key, _} =
        Storage.create_key("service-key", %{service_quotas: %{"exa" => %{"4h" => 1, "week" => 2}}})

      assert :ok == Storage.check_service_quota(key, "exa")

      Storage.record_service_usage(%{
        key_id: key.id,
        service: "exa",
        endpoint: "/search",
        timestamp: DateTime.utc_now()
      })

      assert {:error, msg} = Storage.check_service_quota(key, "exa")
      assert msg =~ "exa 4h quota exceeded"
    end
  end

  describe "trace feedback" do
    test "records feedback linked by trace id" do
      {:ok, key, _} = Storage.create_key("trace-feedback")

      {:ok, trace} =
        Storage.record_trace(%{
          key_id: key.id,
          model: "gpt-4o",
          metadata: %{"trace_id" => "feedback-request"},
          timestamp: DateTime.utc_now()
        })

      assert {:ok, feedback} =
               Storage.record_trace_feedback(%{
                 request_id: "feedback-request",
                 key_id: key.id,
                 rating: "negative",
                 comment: "not useful"
               })

      assert feedback.trace_id == trace.id
      assert [stored] = Storage.get_trace_feedback(trace.id)
      assert stored.rating == "negative"
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
      {:ok, token} = Storage.add_token("test-provider", "api-key", "key-abc")
      {:ok, _} = Storage.set_token_enabled(token.id, false)

      assert Storage.get_tokens("test-provider", "api-key") == []
    end

    test "seed_tokens_from_env only inserts missing tokens" do
      {:ok, _token} = Storage.add_token("openai", "api-key", "existing")

      Storage.seed_tokens_from_env([
        %{provider: "openai", kind: "api-key", tokens: ["existing", "new-token"]}
      ])

      tokens = Storage.list_tokens(%{provider: "openai"})
      assert Enum.map(tokens, & &1.token) |> Enum.sort() == ["existing", "new-token"]
    end

    test "validates token kind and proxy URL" do
      assert {:error, changeset} = Storage.add_token("openai", "session", "tok")
      assert changeset.errors[:kind]

      assert {:error, changeset} =
               Storage.add_token("openai", "api-key", "tok", %{proxy: "file:///etc/passwd"})

      assert changeset.errors[:proxy]
    end
  end

  describe "messages, traces, and stats" do
    test "filters messages, traces, and daily stats" do
      {:ok, key, _} = Storage.create_key("observed")

      Storage.log_message(%{
        key_id: key.id,
        model: "gpt-4o",
        route: "chat",
        user_message: "hello world",
        timestamp: DateTime.utc_now()
      })

      Storage.record_usage(%{
        key_id: key.id,
        model: "gpt-4o",
        input_tokens: 11,
        output_tokens: 7,
        cost_usd: 0.25,
        duration_ms: 20,
        timestamp: DateTime.utc_now()
      })

      Storage.record_trace(%{
        key_id: key.id,
        model: "gpt-4o",
        provider: "openai",
        request_body: "{}",
        response_body: "{}",
        input_tokens: 11,
        output_tokens: 7,
        cost_usd: 0.25,
        duration_ms: 20,
        session_id: "session-1",
        timestamp: DateTime.utc_now()
      })

      assert [%{user_message: "hello world"}] =
               Storage.get_messages(%{search: "hello", per_page: 10})

      assert [%{session_id: "session-1"} = trace] =
               Storage.get_traces(%{session_id: "session-1", per_page: 10})

      assert Storage.get_trace(trace.id).provider == "openai"

      [daily] = Storage.get_daily_stats(%{key_id: key.id})
      assert daily.requests == 1

      stats = Storage.get_stats()
      assert stats.total_requests == 1
      assert length(stats.recent_usage) == 1
    end
  end
end
