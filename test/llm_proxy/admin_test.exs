defmodule LLMProxy.AdminTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Incant.ActionResult
  alias Incant.Service.{Registry, Session}
  alias LLMProxy.Admin.CodexOAuth
  alias LLMProxy.Providers.OpenAICodex.OAuth
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo.SQLite
  alias LLMProxy.TestSupport

  defmodule AdminServer do
    use SafeRPC.Adapter.Server, service: LLMProxy.Admin
  end

  setup do
    TestSupport.checkout_repo()
  end

  test "describes LLMProxy admin as a portable Incant contract" do
    assert %Incant.Admin.Contract{} = contract = Incant.Admin.describe(LLMProxy.Admin)

    assert contract.id == "llm_proxy"
    assert contract.service == :llm_proxy
    assert contract.version == "1"

    resource_ids = Enum.map(contract.resources, & &1.id)
    assert resource_ids == ["api_key", "provider_token", "trace", "message"]

    assert [%{id: "api_key", title: "API Keys"} = api_key | _] = contract.resources

    assert Enum.map(api_key.table.columns, & &1.id) == [
             "name",
             "total_spend_usd",
             "input_tokens",
             "output_tokens",
             "cache_read_tokens",
             "trace_requests"
           ]

    assert Enum.map(api_key.table.columns, & &1.opts[:priority]) == [
             :primary,
             :primary,
             :secondary,
             :secondary,
             :tertiary,
             :secondary
           ]

    assert Enum.map(api_key.table.actions, & &1.id) == ["delete"]
    assert Enum.map(api_key.table.page_actions, & &1.id) == ["create"]

    provider_token = Enum.find(contract.resources, &(&1.id == "provider_token"))
    trace = Enum.find(contract.resources, &(&1.id == "trace"))
    message = Enum.find(contract.resources, &(&1.id == "message"))

    assert Enum.find(trace.table.columns, &(&1.id == "key_id")).opts[:format] == :id
    assert Enum.find(message.table.columns, &(&1.id == "key_id")).opts[:format] == :id

    assert Enum.map(provider_token.table.page_actions, & &1.id) == [
             "codex_oauth_start",
             "codex_oauth_complete"
           ]

    refute Map.has_key?(api_key.opts, :schema)

    assert [%{id: "operations", title: "Operations"} = dashboard] = contract.dashboards

    assert Enum.map(dashboard.widgets, & &1.id) == [
             "api_keys",
             "requests",
             "spend",
             "input_tokens",
             "output_tokens",
             "recent_usage",
             "service_usage"
           ]

    assert dashboard.grid == %{columns: 10}
    assert Enum.map(dashboard.widgets, & &1.opts[:span]) == [2, 2, 2, 2, 2, 7, 3]

    recent_usage = Enum.find(dashboard.widgets, &(&1.id == "recent_usage"))

    assert Enum.map(recent_usage.opts.columns, & &1.name) == [
             :timestamp,
             :provider,
             :model,
             :input_tokens,
             :output_tokens,
             :cost_usd,
             :duration_ms,
             :ttft_ms,
             :key_id
           ]

    assert Enum.map(recent_usage.opts.columns, & &1.opts[:label]) == [
             "Timestamp",
             "Provider",
             "Model",
             "Input tokens",
             "Output tokens",
             "Cost",
             "Duration",
             "TTFT",
             "Key"
           ]

    assert recent_usage.opts[:preview_rows] == 10

    assert Enum.map(recent_usage.opts.columns, & &1.opts[:priority]) == [
             :primary,
             :secondary,
             :primary,
             :secondary,
             :tertiary,
             :secondary,
             :tertiary,
             :tertiary,
             :tertiary
           ]

    assert Enum.all?(dashboard.widgets, fn widget -> not Map.has_key?(widget.opts, :query) end)
  end

  test "executes Operations dashboard widgets through Incant service session" do
    socket = socket_path("dashboard-widgets")
    {:ok, server} = AdminServer.start_link(socket: socket)
    Sandbox.allow(SQLite, self(), server)

    {:ok, key, _raw_key} = Storage.create_key("dashboard-widget-user")
    Storage.update_key_usage(key, %{input: 123, output: 45, cost_usd: 0.67})

    assert {:ok, _usage} =
             Storage.record_usage(%{
               key_id: key.id,
               model: "dashboard-model",
               input_tokens: 123,
               output_tokens: 45,
               cost_usd: 0.67,
               provider: "openai",
               timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    bindings = %{llm_proxy: %{socket: socket, modules: [LLMProxy.Admin]}}

    assert {:ok, %Registry{entries: [entry]}} = Registry.from_bindings(bindings)

    session = Session.new(entry)

    assert {:ok, 1} = Session.run_widget(session, "operations", "api_keys")
    assert {:ok, 1} = Session.run_widget(session, "operations", "requests")
    assert {:ok, 0.67} = Session.run_widget(session, "operations", "spend")
    assert {:ok, 123} = Session.run_widget(session, "operations", "input_tokens")
    assert {:ok, 45} = Session.run_widget(session, "operations", "output_tokens")

    assert {:ok,
            %{
              "columns" => [
                "timestamp",
                "provider",
                "model",
                "input_tokens",
                "output_tokens",
                "cost_usd",
                "duration_ms",
                "ttft_ms",
                "key_id"
              ],
              "rows" => [%{"model" => "dashboard-model"}]
            }} = Session.run_widget(session, "operations", "recent_usage")

    assert {:ok, %{"columns" => ["service", "count"], "rows" => []}} =
             Session.run_widget(session, "operations", "service_usage")

    GenServer.stop(server)
  end

  test "runs API key creation page action" do
    assert {:ok, %ActionResult.Job{id: "api_key:" <> _id, meta: meta}} =
             LLMProxy.Admin.run_action(
               "api_key",
               "create",
               %{assigns: %{"name" => "operator-test", "trace_requests" => true}},
               %{}
             )

    assert %{id: id, name: "operator-test", token: "sk-proxy-" <> _} = meta
    assert key = Storage.find_key(meta.token)
    assert key.id == id
    assert key.trace_requests == true
  end

  test "runs Codex OAuth start page action" do
    assert {:ok, %ActionResult.Job{id: "codex_oauth", meta: %{"oauth" => oauth}}} =
             LLMProxy.Admin.run_action("provider_token", "codex_oauth_start", %{}, %{})

    assert %{
             "authorization_url" => authorization_url,
             "state" => state,
             "verifier" => verifier
           } = oauth

    assert authorization_url =~ "https://auth.openai.com/oauth/authorize"
    assert authorization_url =~ URI.encode_query(%{state: state})
    assert is_binary(verifier)
  end

  test "stores Codex OAuth credentials from live admin process" do
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

  test "runs implemented API key and token row actions" do
    {:ok, key, _raw_key} = Storage.create_key("admin-delete")
    {:ok, token} = Storage.add_token("openai", "api-key", "admin-token")

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "disable",
               %{id: to_string(token.id)},
               %{}
             )

    [disabled] = Storage.list_tokens(%{provider: "openai"})
    assert disabled.enabled == false

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "enable",
               %{id: to_string(token.id)},
               %{}
             )

    [enabled] = Storage.list_tokens(%{provider: "openai"})
    assert enabled.enabled == true

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "remove",
               %{id: to_string(token.id)},
               %{}
             )

    assert Storage.list_tokens(%{provider: "openai"}) == []

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action("api_key", "delete", %{id: key.id}, %{})

    assert Storage.list_keys() == []
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "llm-proxy-admin-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
